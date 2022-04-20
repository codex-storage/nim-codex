## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/stew/shims/net
import pkg/libp2pdht/discv5/protocol as discv5

export discv5

type
  Discovery* = ref object
    findBlockProviders_var*: proc(d: Discovery, cid: Cid): seq[SignedPeerRecord] {.gcsafe.}
    publishProvide_var*: proc(d: Discovery, cid: Cid) {.gcsafe.}

proc new*(
  T: type Discovery,
  localInfo: PeerInfo,
  discoveryPort: Port,
  bootstrapNodes = newSeq[SignedPeerRecord](),
  ): T =

  T()

proc findPeer*(
  d: Discovery,
  peerId: PeerID): Future[?PeerRecord] {.async.} =
  return none(PeerRecord)

proc findBlockProviders*(
  d: Discovery,
  cid: Cid): Future[seq[SignedPeerRecord]] {.async.} =
  if isNil(d.findBlockProviders_var): return

  return d.findBlockProviders_var(d, cid)

proc publishProvide*(d: Discovery, cid: Cid) {.async.} =
  if isNil(d.publishProvide_var): return
  d.publishProvide_var(d, cid)


proc start*(d: Discovery) {.async.} =
  discard

proc stop*(d: Discovery) {.async.} =
  discard
