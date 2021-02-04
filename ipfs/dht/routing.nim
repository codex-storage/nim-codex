## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/libp2p/peerinfo
import pkg/libp2p/cid

export peerinfo
export cid

type
  RoutingTable* = object
    peers: seq[PeerInfo]

proc add*(table: var RoutingTable, peer: PeerInfo) =
  table.peers.add(peer)

proc closest*(table: RoutingTable, id: Cid): seq[PeerInfo] =
  table.peers
