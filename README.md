# Synopsis

This package aims to provide a thin layer for bittorrent protocol.
Basically it provides serialization\deserealization and some widely
used routines.

# Description

## Modules

The module hierarhy is tend to be:

* Data.Torrent — for torrent metainfo, data verification, etc
* Network.BitTorrent.Peer     — common peer related types.
* Network.BitTorrent.PeerWire — peer wire TCP message passing.
* Network.BitTorrent.Tracker  — tracker HTTP message passing.

# Status

The protocol has many extensions[1] and it's seems like no one want to
use just core protocol, at least I'm not. Any modern application that
uses bittorrent protocol in any way will use some subset of extensions
anyway. Thus it's reasonable to implement at least some part of widely
used extensions here, so we could provide nice high level API and well
integrated interface.

This section should keep track current state of package in respect of
BEP's.  Please _don't_ use this list as issue or bug tracker or TODO
list or anything else: when in doubt don't change the table.

In order to keep table compact we describe table layout at first:

* **BEP #**   — Just number of enchancement.
* **Title**   — Full official enchancement name.
* **Modules** — modules that _directly_ relates to the BEP. This is where
  BEP implemented, where we should look for the BEP. If a module has
  only changes due to integration with the BEP then it _should not_ be
  listed in the **Modules** list.
* **Status** — is the current state of the BEP. Status lifecycle has the
  only way: Want -> Implemented -> Tested -> Integrated -> Done. You
  might use (A -> B) to indicate intermediate steps.  Note that
  implemented _doesn't_ means that BEP is ready to use, it _will_ be
  ready to use only after it pass Tested, Integrated and finally
  becomes Done.

We should try keep table in order of priority, so first BEPs should be
are most important and last BEPs are least important. (but important
too)

| BEP # | Title                                      | Modules                             | Status
|:-----:|:------------------------------------------:|:------------------------------------|:-----------
| 3     | The BitTorrent Protocol Specification      | Data.Torrent                        | Implemented
|       |                                            | Network.BitTorrent.Peer             |
|       |                                            | Network.BitTorrent.PeerWire         |
|       |                                            | Network.BitTorrent.Tracker          |
| 4     | Known Number Allocations                   | Network.BitTorrent.Extension        | Want -> Implemented
| 20    | Peer ID Conventions                        | Network.BitTorrent.Peer.ID          | Want -> Implemented
|       |                                            | Network.BitTorrent.Peer.ClientInfo  |
| 9     | Extension for Peers to Send Metadata Files |                                     | Want
| 23    | Tracker Return Compact Peer Lists          | Network.BitTorrent.Tracker.Protocol | Implemented
|       |                                            | Network.BitTorrent.PeerWire.Message |
| 5     | DHT                                        |                                     | Want
| 6     | Fast Extension                             | Network.BitTorrent.PeerWire.Message | Want -> Implemented

# Build Status

[![Build Status][1]][2]

[1]: https://travis-ci.org/pxqr/network-bittorrent.png
[2]: https://travis-ci.org/pxqr/network-bittorrent


### Footnotes

[1] More precisely enchancements, but we'll use that word.
