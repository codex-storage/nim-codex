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
    key: PrivateKey
    announceAddrs: seq[MultiAddress]
    record: SignedPeerRecord

proc toNodeId*(cid: Cid): NodeId =
  ## Cid to discovery id
  ##

  readUintBE[256](keccak256.digest(cid.data.buffer).data)

proc toNodeId*(host: ca.Address): NodeId =
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
    (await d.protocol.getProviders(cid.toNodeId())).mapFailure, error:
    trace "Error finding providers for block", cid = $cid, error = error.msg

  return providers

method provide*(d: Discovery, cid: Cid) {.async, base.} =
  ## Provide a bock Cid
  ##

  trace "Providing block", cid = $cid
  let
    nodes = await d.protocol.addProvider(
      cid.toNodeId(), d.record)

  if nodes.len <= 0:
    trace "Couldn't provide to any nodes!"

  trace "Provided to nodes", nodes = nodes.len

method find*(
  d: Discovery,
  host: ca.Address): Future[seq[SignedPeerRecord]] {.async, base.} =
  ## Find host providers
  ##

  trace "Finding providers for host", host = $host
  without var providers =?
    (await d.protocol.getProviders(host.toNodeId())).mapFailure, error:
    trace "Error finding providers for host", host = $host, exc = error.msg
    return

  if providers.len <= 0:
    trace "No providers found", host = $host
    return

  providers.sort do(a, b: SignedPeerRecord) -> int:
    system.cmp[uint64](a.data.seqNo, b.data.seqNo)

  return providers

method provide*(d: Discovery, host: ca.Address) {.async, base.} =
  ## Provide hosts
  ##

  trace "Providing host", host = $host
  let
    nodes = await d.protocol.addProvider(
    host.toNodeId(), d.record)
  if nodes.len > 0:
    trace "Provided to nodes", nodes = nodes.len

method removeProvider*(d: Discovery, peerId: PeerId): Future[void] {.base.} =
  ## Remove provider from providers table
  ##

  trace "Removing provider", peerId
  d.protocol.removeProvidersLocal(peerId)

proc updateRecord*(d: Discovery, addrs: openArray[MultiAddress]) =
  ## Update providers record
  ##

  d.announceAddrs = @addrs
  d.record = SignedPeerRecord.init(
    d.key,
    PeerRecord.init(
      PeerId.init(d.key).expect("Should construct PeerId"),
      d.announceAddrs)).expect("Should construct signed record")

  if not d.protocol.isNil:
    d.protocol.updateRecord(d.record.some)
      .expect("should update SPR")

proc start*(d: Discovery) {.async.} =
  d.protocol.open()
  await d.protocol.start()

proc stop*(d: Discovery) {.async.} =
  await d.protocol.closeWait()

proc new*(
  T: type Discovery,
  key: PrivateKey,
  discoveryIp = IPv4_any(),
  discoveryPort = 0.Port,
  announceAddrs: openArray[MultiAddress] = [],
  bootstrapNodes: openArray[SignedPeerRecord] = [],
  store: Datastore = SQLiteDatastore.new(Memory)
  .expect("Should not fail!")): T =

  let
    announceAddrs =
      if announceAddrs.len <= 0:
        @[
          MultiAddress.init(
            ValidIpAddress.init(discoveryIp),
            IpTransportProtocol.tcpProtocol,
            discoveryPort)]
      else:
        @announceAddrs

  var
    self = T(key: key)

  self.updateRecord(announceAddrs)

  self.protocol = newProtocol(
    key,
    bindIp = discoveryIp,
    bindPort = discoveryPort,
    record = self.record,
    bootstrapRecords = bootstrapNodes,
    rng = Rng.instance(),
    providers = ProvidersManager.new(store))

  self
