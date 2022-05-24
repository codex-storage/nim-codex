## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/algorithm

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope
import pkg/questionable
import pkg/questionable/results
import pkg/stew/shims/net
import pkg/contractabi/address as ca
import pkg/libp2pdht/discv5/protocol as discv5

import ./rng
import ./errors

export discv5

# TODO: If generics in methods had not been
# deprecated, this could have been implemented
# much more elegantly.

type
  Discovery* = ref object of RootObj
    protocol: discv5.Protocol
    localInfo: PeerInfo

proc new*(
  T: type Discovery,
  localInfo: PeerInfo,
  discoveryPort = 0.Port,
  bootstrapNodes: seq[SignedPeerRecord] = @[],
  ): T =

  T(
    protocol: newProtocol(
      localInfo.privateKey,
      bindPort = discoveryPort,
      record = localInfo.signedPeerRecord,
      bootstrapRecords = bootstrapNodes,
      rng = Rng.instance()
    ),
    localInfo: localInfo)

proc toDiscoveryId*(cid: Cid): NodeId =
  ## Cid to discovery id
  ##

  readUintBE[256](keccak256.digest(cid.data.buffer).data)

proc toDiscoveryId*(host: ca.Address): NodeId =
  ## Eth address to discovery id
  ##

  readUintBE[256](keccak256.digest(host.toArray).data)

proc findPeer*(
  d: Discovery,
  peerId: PeerID): Future[?PeerRecord] {.async.} =
  let
    node = await d.protocol.resolve(toNodeId(peerId))

  return
    if node.isSome():
      some(node.get().record.data)
    else:
      none(PeerRecord)

method find*(
  d: Discovery,
  cid: Cid): Future[seq[SignedPeerRecord]] {.async, base.} =
  ## Find block providers
  ##

  trace "Finding providers for block", cid = $cid
  without providers =?
    (await d.protocol.getProviders(cid.toDiscoveryId())).mapFailure, error:
    trace "Error finding providers for block", cid = $cid, error = error.msg

  return providers

method provide*(d: Discovery, cid: Cid) {.async, base.} =
  ## Provide a bock Cid
  ##

  trace "Providing block", cid = $cid
  let
    nodes = await d.protocol.addProvider(
      cid.toDiscoveryId(),
      d.localInfo.signedPeerRecord)

  if nodes.len <= 0:
    trace "Couldn't provide to any nodes!"

  trace "Provided to nodes", nodes = nodes.len

method find*(
  d: Discovery,
  host: ca.Address): Future[seq[SignedPeerRecord]] {.async, base.} =
  ## Find host providers
  ##

  trace "Finding providers for host", host = host.toHex
  without var providers =?
    (await d.protocol.getProviders(host.toDiscoveryId())).mapFailure, error:
    trace "Error finding providers for host", cid, error
    return

  if providers.len <= 0:
    trace "No providers found", host = host.toHex
    return

  providers.sort do(a, b: SignedPeerRecord) -> int:
    system.cmp[uint64](a.data.seqNo, b.data.seqNo)

  return providers

method provide*(d: Discovery, host: ca.Address) {.async, base.} =
  ## Provide hosts
  ##

  trace "Providing host", host = host.toHex
  let
    nodes = await d.protocol.addProvider(
    host.toDiscoveryId(),
    d.localInfo.signedPeerRecord)
  if nodes.len > 0:
    trace "Provided to nodes", nodes = nodes.len

proc start*(d: Discovery) {.async.} =
  d.protocol.updateRecord(d.localInfo.signedPeerRecord).expect("updating SPR")
  d.protocol.open()
  d.protocol.start()

proc stop*(d: Discovery) {.async.} =
  await d.protocol.closeWait()
