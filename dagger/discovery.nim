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

import rng

export discv5

type
  Discovery* = ref object
    protocol: discv5.Protocol
    localInfo: PeerInfo

proc new*(
  T: type Discovery,
  localInfo: PeerInfo,
  discoveryPort: Port,
  bootstrapNodes = newSeq[SignedPeerRecord](),
  ): T =

  T(
    protocol: newProtocol(
      localInfo.privateKey,
      bindPort = discoveryPort,
      record = localInfo.signedPeerRecord,
      bootstrapRecords = bootstrapNodes,
      rng = Rng.instance()
    ),
    localInfo: localInfo
  )

proc findPeer*(
  d: Discovery,
  peerId: PeerID): Future[?PeerRecord] {.async.} =
  let node = await d.protocol.resolve(toNodeId(peerId))
  return
    if node.isSome():
      some(node.get().record.data)
    else:
      none(PeerRecord)

proc toDiscoveryId*(cid: Cid): NodeId =
  ## To discovery id
  readUintBE[256](keccak256.digest(cid.data.buffer).data)

proc findBlockProviders*(
  d: Discovery,
  cid: Cid): Future[seq[SignedPeerRecord]] {.async.} =
  return (await d.protocol.getProviders(cid.toDiscoveryId())).get()

proc publishProvide*(d: Discovery, cid: Cid) {.async.} =
  let bid = cid.toDiscoveryId()
  discard await d.protocol.addProvider(bid, d.localInfo.signedPeerRecord)


proc start*(d: Discovery) {.async.} =
  d.protocol.updateRecord(d.localInfo.signedPeerRecord).expect("updating SPR")
  d.protocol.open()
  d.protocol.start()

proc stop*(d: Discovery) {.async.} =
  await d.protocol.closeWait()
