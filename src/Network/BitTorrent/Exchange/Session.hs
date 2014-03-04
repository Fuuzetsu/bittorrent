{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE DeriveDataTypeable   #-}
module Network.BitTorrent.Exchange.Session
       ( -- * Session
         Session
       , LogFun
       , sessionLogger

         -- * Construction
       , newSession
       , closeSession
       , withSession

         -- * Connection Set
       , connect
       , establish

         -- * Events
       , waitMetadata
       ) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception hiding (Handler)
import Control.Lens
import Control.Monad.Logger
import Control.Monad.Reader
import Data.ByteString as BS
import Data.ByteString.Lazy as BL
import Data.Conduit
import Data.Conduit.List as CL (iterM)
import Data.Maybe
import Data.Map as M
import Data.Monoid
import Data.Set  as S
import Data.Text as T
import Data.Typeable
import Text.PrettyPrint hiding ((<>))
import Text.PrettyPrint.Class
import System.Log.FastLogger (LogStr, ToLogStr (..))

import Data.BEncode as BE
import Data.Torrent (InfoDict (..))
import Data.Torrent.Bitfield as BF
import Data.Torrent.InfoHash
import Data.Torrent.Piece
import qualified Data.Torrent.Piece as Torrent (Piece ())
import Network.BitTorrent.Core
import Network.BitTorrent.Exchange.Block   as Block
import Network.BitTorrent.Exchange.Connection
import Network.BitTorrent.Exchange.Connection.Status
import Network.BitTorrent.Exchange.Message as Message
import Network.BitTorrent.Exchange.Session.Metadata as Metadata
import Network.BitTorrent.Exchange.Session.Status   as SS
import System.Torrent.Storage

{-----------------------------------------------------------------------
--  Exceptions
-----------------------------------------------------------------------}

data ExchangeError
  = InvalidRequest BlockIx StorageFailure
  | CorruptedPiece PieceIx
    deriving (Show, Typeable)

instance Exception ExchangeError

packException :: Exception e => (e -> ExchangeError) -> IO a -> IO a
packException f m = try m >>= either (throwIO . f) return

{-----------------------------------------------------------------------
--  Session
-----------------------------------------------------------------------}
-- TODO unmap storage on zero connections

data Cached a = Cached
  { cachedValue :: !a
  , cachedData  :: BL.ByteString -- keep lazy
  }

cache :: BEncode a => a -> Cached a
cache s = Cached s (BE.encode s)

-- | Logger function.
type LogFun = Loc -> LogSource -> LogLevel -> LogStr -> IO ()

data Session = Session
  { sessionPeerId          :: !(PeerId)
  , sessionTopic           :: !(InfoHash)
  , sessionLogger          :: !(LogFun)

  , metadata               :: !(MVar Metadata.Status)
  , infodict               :: !(MVar (Cached InfoDict))

  , status                 :: !(MVar SessionStatus)
  , storage                :: !(Storage)

  , connectionsPrefs       :: !ConnectionPrefs

    -- | Connections either waiting for TCP/uTP 'connect' or waiting
    -- for BT handshake.
  , connectionsPending     :: !(TVar (Set (PeerAddr IP)))

    -- | Connections successfully handshaked and data transfer can
    -- take place.
  , connectionsEstablished :: !(TVar (Map (PeerAddr IP) (Connection Session)))

    -- | TODO implement choking mechanism
  , connectionsUnchoked    ::  [PeerAddr IP]

    -- | Messages written to this channel will be sent to the all
    -- connections, including pending connections (but right after
    -- handshake).
  , connectionsBroadcast   :: !(Chan Message)
  }

{-----------------------------------------------------------------------
--  Session construction
-----------------------------------------------------------------------}

newSession :: LogFun
           -> PeerAddr (Maybe IP) -- ^ /external/ address of this peer;
           -> FilePath            -- ^ root directory for content files;
           -> InfoDict            -- ^ torrent info dictionary;
           -> IO Session          -- ^
newSession logFun addr rootPath dict = do
  pid         <- maybe genPeerId return (peerId addr)
  store       <- openInfoDict ReadWriteEx rootPath dict
  statusVar   <- newMVar $ sessionStatus (BF.haveNone (totalPieces store))
                                         (piPieceLength (idPieceInfo dict))
  metadataVar <- newMVar (error "sessionMetadata")
  infodictVar <- newMVar (cache dict)

  pSetVar     <- newTVarIO S.empty
  eSetVar     <- newTVarIO M.empty
  chan        <- newChan

  return Session
    { sessionPeerId          = pid
    , sessionTopic           = idInfoHash dict
    , sessionLogger          = logFun

    , metadata               = metadataVar
    , infodict               = infodictVar

    , status                 = statusVar
    , storage                = store

    , connectionsPrefs       = def
    , connectionsPending     = pSetVar
    , connectionsEstablished = eSetVar
    , connectionsUnchoked    = []
    , connectionsBroadcast   = chan
    }

closeSession :: Session -> IO ()
closeSession Session {..} = do
  close storage
{-
  hSet <- atomically $ do
    pSet <- swapTVar connectionsPending     S.empty
    eSet <- swapTVar connectionsEstablished S.empty
    return pSet
  mapM_ kill hSet
-}

withSession :: ()
withSession = error "withSession"

{-----------------------------------------------------------------------
--  Logging
-----------------------------------------------------------------------}

instance MonadLogger (Connected Session) where
  monadLoggerLog loc src lvl msg = do
    conn <- ask
    ses  <- asks connSession
    addr <- asks connRemoteAddr
    let addrSrc = src <> " @ " <> T.pack (render (pretty addr))
    liftIO $ sessionLogger ses loc addrSrc lvl (toLogStr msg)

logMessage :: MonadLogger m => Message -> m ()
logMessage msg = logDebugN $ T.pack (render (pretty msg))

logEvent   :: MonadLogger m => Text    -> m ()
logEvent       = logInfoN

{-----------------------------------------------------------------------
--  Connection set
-----------------------------------------------------------------------}
--- Connection status transition:
---
--- pending -> established -> finished -> closed
---    |           \|/                      /|\
---    \-------------------------------------|
---
--- Purpose of slots:
---   1) to avoid duplicates
---   2) connect concurrently
---

-- | Add connection to the pending set.
pendingConnection :: PeerAddr IP -> Session -> STM Bool
pendingConnection addr Session {..} = do
  pSet <- readTVar connectionsPending
  eSet <- readTVar connectionsEstablished
  if (addr `S.member` pSet) || (addr `M.member` eSet)
    then return False
    else do
      modifyTVar' connectionsPending (S.insert addr)
      return True

-- | Pending connection successfully established, add it to the
-- established set.
establishedConnection :: Connected Session ()
establishedConnection = do
  conn         <- ask
  addr         <- asks connRemoteAddr
  Session {..} <- asks connSession
  liftIO $ atomically $ do
    modifyTVar connectionsPending     (S.delete addr)
    modifyTVar connectionsEstablished (M.insert addr conn)

-- | Either this or remote peer decided to finish conversation
-- (conversation is alread /established/ connection), remote it from
-- the established set.
finishedConnection :: Connected Session ()
finishedConnection = do
  Session {..} <- asks connSession
  addr         <- asks connRemoteAddr
  liftIO $ atomically $ do
    modifyTVar connectionsEstablished $ M.delete addr

-- | There are no state for this connection, remove it from the all
-- sets.
closedConnection :: PeerAddr IP -> Session -> STM ()
closedConnection addr Session {..} = do
  modifyTVar connectionsPending     $ S.delete addr
  modifyTVar connectionsEstablished $ M.delete addr

getConnectionConfig :: Session -> IO (ConnectionConfig Session)
getConnectionConfig s @ Session {..} = do
  chan <- dupChan connectionsBroadcast
  let sessionLink = SessionLink {
      linkTopic        = sessionTopic
    , linkPeerId       = sessionPeerId
    , linkMetadataSize = Nothing
    , linkOutputChan   = Just chan
    , linkSession      = s
    }
  return ConnectionConfig
    { cfgPrefs   = connectionsPrefs
    , cfgSession = sessionLink
    , cfgWire    = mainWire
    }

type Finalizer      = IO ()
type Runner = (ConnectionConfig Session -> IO ())

runConnection :: Runner -> Finalizer -> PeerAddr IP -> Session -> IO ()
runConnection runner finalize addr set @ Session {..} = do
    _ <- forkIO (action `finally` cleanup)
    return ()
  where
    action = do
      notExist <- atomically $ pendingConnection addr set
      when notExist $ do
        cfg <- getConnectionConfig set
        runner cfg

    cleanup = do
      finalize
--      runStatusUpdates status (SS.resetPending addr)
      -- TODO Metata.resetPending addr
      atomically $ closedConnection addr set

-- | Establish connection from scratch. If this endpoint is already
-- connected, no new connections is created. This function do not block.
connect :: PeerAddr IP -> Session -> IO ()
connect addr = runConnection (connectWire addr) (return ()) addr

-- | Establish connection with already pre-connected endpoint. If this
-- endpoint is already connected, no new connections is created. This
-- function do not block.
--
--  'PendingConnection' will be closed automatically, you do not need
--  to call 'closePending'.
establish :: PendingConnection -> Session -> IO ()
establish conn = runConnection (acceptWire conn) (closePending conn)
                 (pendingPeer conn)

-- | Why do we need this message?
type BroadcastMessage = ExtendedCaps -> Message

broadcast :: BroadcastMessage -> Session -> IO ()
broadcast = error "broadcast"

{-----------------------------------------------------------------------
--  Helpers
-----------------------------------------------------------------------}

waitMVar :: MVar a -> IO ()
waitMVar m = withMVar m (const (return ()))

-- This function appear in new GHC "out of box". (moreover it is atomic)
tryReadMVar :: MVar a -> IO (Maybe a)
tryReadMVar m = do
  ma <- tryTakeMVar m
  maybe (return ()) (putMVar m) ma
  return ma

withStatusUpdates :: StatusUpdates a -> Wire Session a
withStatusUpdates m = do
  Session {..} <- asks connSession
  liftIO $ runStatusUpdates status m

withMetadataUpdates :: Updates a -> Connected Session a
withMetadataUpdates m = do
  Session {..} <- asks connSession
  addr         <- asks connRemoteAddr
  liftIO $ runUpdates metadata addr m

getThisBitfield :: Wire Session Bitfield
getThisBitfield = do
  ses <- asks connSession
  liftIO $ SS.getBitfield (status ses)

readBlock :: BlockIx -> Storage -> IO (Block BL.ByteString)
readBlock bix @ BlockIx {..} s = do
  p <- packException (InvalidRequest bix) $ do readPiece ixPiece s
  let chunk = BL.take (fromIntegral ixLength) $
              BL.drop (fromIntegral ixOffset) (pieceData p)
  if BL.length chunk == fromIntegral ixLength
    then return  $ Block ixPiece ixOffset chunk
    else throwIO $ InvalidRequest bix (InvalidSize ixLength)

-- |
tryReadMetadataBlock :: PieceIx
   -> Connected Session (Maybe (Torrent.Piece BS.ByteString, Int))
tryReadMetadataBlock pix = do
  Session {..} <- asks connSession
  mcached      <- liftIO (tryReadMVar infodict)
  case mcached of
    Nothing            -> error "tryReadMetadataBlock"
    Just (Cached {..}) -> error "tryReadMetadataBlock"

sendBroadcast :: PeerMessage msg => msg -> Wire Session ()
sendBroadcast msg = do
  Session {..} <- asks connSession
  error "sendBroadcast"
--  liftIO $ msg `broadcast` sessionConnections

waitMetadata :: Session -> IO InfoDict
waitMetadata Session {..} = cachedValue <$> readMVar infodict

{-----------------------------------------------------------------------
--  Triggers
-----------------------------------------------------------------------}

-- | Trigger is the reaction of a handler at some event.
type Trigger = Wire Session ()

interesting :: Trigger
interesting = do
  addr <- asks connRemoteAddr
  sendMessage (Interested True)
  sendMessage (Choking    False)
  tryFillRequestQueue

fillRequestQueue :: Trigger
fillRequestQueue = do
  maxN <- lift getMaxQueueLength
  rbf  <- use connBitfield
  addr <- asks connRemoteAddr
  blks <- withStatusUpdates $ do
    n <- getRequestQueueLength addr
    scheduleBlocks addr rbf (maxN - n)
  mapM_ (sendMessage . Request) blks

tryFillRequestQueue :: Trigger
tryFillRequestQueue = do
  allowed <- canDownload <$> use connStatus
  when allowed $ do
    fillRequestQueue

{-----------------------------------------------------------------------
--  Incoming message handling
-----------------------------------------------------------------------}

type Handler msg = msg -> Wire Session ()

handleStatus :: Handler StatusUpdate
handleStatus s = do
  connStatus %= over remoteStatus (updateStatus s)
  case s of
    Interested _     -> return ()
    Choking    True  -> do
      addr <- asks connRemoteAddr
      withStatusUpdates (SS.resetPending addr)
    Choking    False -> tryFillRequestQueue

handleAvailable :: Handler Available
handleAvailable msg = do
  connBitfield %= case msg of
    Have     ix -> BF.insert ix
    Bitfield bf -> const     bf

  thisBf <- getThisBitfield
  case msg of
    Have     ix
      | ix `BF.member`     thisBf -> return ()
      |     otherwise             -> interesting
    Bitfield bf
      | bf `BF.isSubsetOf` thisBf -> return ()
      |     otherwise             -> interesting

handleTransfer :: Handler Transfer
handleTransfer (Request bix) = do
  Session {..} <- asks connSession
  bitfield <- getThisBitfield
  upload   <- canUpload <$> use connStatus
  when (upload && ixPiece bix `BF.member` bitfield) $ do
    blk <- liftIO $ readBlock bix storage
    sendMessage (Message.Piece blk)

handleTransfer (Message.Piece   blk) = do
  Session {..} <- asks connSession
  isSuccess <- withStatusUpdates (SS.pushBlock blk storage)
  case isSuccess of
    Nothing -> liftIO $ throwIO $ userError "block is not requested"
    Just isCompleted -> do
      when isCompleted $ do
        sendBroadcast (Have (blkPiece blk))
--        maybe send not interested
      tryFillRequestQueue

handleTransfer (Cancel  bix) = filterQueue (not . (transferResponse bix))
  where
    transferResponse bix (Transfer (Message.Piece blk)) = blockIx blk == bix
    transferResponse _    _                             = False

{-----------------------------------------------------------------------
--  Metadata exchange
-----------------------------------------------------------------------}
-- TODO introduce new metadata exchange specific exceptions

waitForMetadata :: Trigger
waitForMetadata = do
  Session {..} <- asks connSession
  needFetch    <- liftIO (isEmptyMVar infodict)
  when needFetch $ do
    canFetch   <- allowed ExtMetadata <$> use connExtCaps
    if canFetch
      then tryRequestMetadataBlock
      else liftIO (waitMVar infodict)

tryRequestMetadataBlock :: Trigger
tryRequestMetadataBlock = do
  mpix <- lift $ withMetadataUpdates Metadata.scheduleBlock
  case mpix of
    Nothing  -> error "tryRequestMetadataBlock"
    Just pix -> sendMessage (MetadataRequest pix)

metadataCompleted :: InfoDict -> Trigger
metadataCompleted dict = do
  Session {..} <- asks connSession
  liftIO $ putMVar infodict (cache dict)

handleMetadata :: Handler ExtendedMetadata
handleMetadata (MetadataRequest pix) =
    lift (tryReadMetadataBlock pix) >>= sendMessage . mkResponse
  where
    mkResponse  Nothing              = MetadataReject pix
    mkResponse (Just (piece, total)) = MetadataData   piece total

handleMetadata (MetadataData   {..}) = do
  ih    <- asks connTopic
  mdict <- lift $ withMetadataUpdates (Metadata.pushBlock piece ih)
  case mdict of
    Nothing   -> tryRequestMetadataBlock -- not completed, need all blocks
    Just dict -> metadataCompleted dict  -- complete, wake up payload fetch

handleMetadata (MetadataReject  pix) = do
  lift $ withMetadataUpdates (Metadata.cancelPending pix)

handleMetadata (MetadataUnknown _  ) = do
  logInfoN "Unknown metadata message"

{-----------------------------------------------------------------------
--  Main entry point
-----------------------------------------------------------------------}

acceptRehandshake :: ExtendedHandshake -> Trigger
acceptRehandshake ehs = error "acceptRehandshake"

handleExtended :: Handler ExtendedMessage
handleExtended (EHandshake     ehs) = acceptRehandshake ehs
handleExtended (EMetadata  _   msg) = handleMetadata msg
handleExtended (EUnknown   _   _  ) = logWarnN "Unknown extension message"

handleMessage :: Handler Message
handleMessage KeepAlive       = return ()
handleMessage (Status s)      = handleStatus s
handleMessage (Available msg) = handleAvailable msg
handleMessage (Transfer  msg) = handleTransfer msg
handleMessage (Port      n)   = error "handleMessage"
handleMessage (Fast      _)   = error "handleMessage"
handleMessage (Extended  msg) = handleExtended msg

exchange :: Wire Session ()
exchange = do
  waitForMetadata
  bf <- getThisBitfield
  sendMessage (Bitfield bf)
  awaitForever handleMessage

mainWire :: Wire Session ()
mainWire = do
  lift establishedConnection
  Session {..} <- asks connSession
  lift $ resizeBitfield (totalPieces storage)
  logEvent "Connection established"
  iterM logMessage =$= exchange =$= iterM logMessage
  lift finishedConnection

data Event = NewMessage (PeerAddr IP) Message
           | Timeout -- for scheduling

type Exchange a = Wire Session a

awaitEvent :: Exchange Event
awaitEvent = error "awaitEvent"

yieldEvent :: Exchange Event
yieldEvent = error "yieldEvent"
