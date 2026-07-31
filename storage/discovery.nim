## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/algorithm
import std/net
import std/random
import std/sequtils

import pkg/chronos
import pkg/libp2p/[cid, multicodec, routing_record, signed_envelope]
import pkg/libp2p_mix
import pkg/questionable
import pkg/questionable/results
import pkg/contractabi/address as ca
import pkg/codexdht/discv5/[routing_table, protocol as discv5]
from pkg/nimcrypto import keccak256

import ./rng as storage_rng
import ./utils/addrutils
import ./utils/mixidentity
import ./errors
import ./logutils
import ./dht_proxy/client as dht_proxy_client

export discv5

# TODO: If generics in methods had not been
# deprecated, this could have been implemented
# much more elegantly.

logScope:
  topics = "storage discovery"

type Discovery* = ref object of RootObj
  protocol*: discv5.Protocol # dht protocol
  key: PrivateKey # private key
  peerId: PeerId # the peer id of the local node
  providerAddrs*: seq[MultiAddress]
    # TCP addresses as part of the provider records, exposed for debugging
  providerRecord*: ?SignedPeerRecord
    # record to advertice node connection information, this carry any
    # address that the node can be connected on
  discoveryAddrs*: seq[MultiAddress]
    # UDP addresses as part of the local record, exposed for debugging
  isStarted: bool
  store: Datastore
  mixProto*: MixProtocol
  dhtMixProxies*: seq[SignedPeerRecord]
  privateQueries: bool
  onAddrChange*: proc() {.gcsafe, raises: [].}

proc toNodeId*(cid: Cid): NodeId =
  ## Cid to discovery id
  ##

  readUintBE[256](keccak256.digest(cid.data.buffer).data)

proc toNodeId*(host: ca.Address): NodeId =
  ## Eth address to discovery id
  ##

  readUintBE[256](keccak256.digest(host.toArray).data)

proc findPeer*(
    d: Discovery, peerId: PeerId
): Future[?PeerRecord] {.async: (raises: [CancelledError]).} =
  trace "protocol.resolve..."
  ## Find peer using the given Discovery object
  ##

  try:
    let node = await d.protocol.resolve(toNodeId(peerId))

    return
      if node.isSome():
        node.get().record.data.some
      else:
        PeerRecord.none
  except CancelledError as exc:
    warn "Error finding peer", peerId = peerId, exc = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error finding peer", peerId = peerId, exc = exc.msg

  return PeerRecord.none

method findViaMix*(
    d: Discovery, cid: Cid
): Future[?!seq[SignedPeerRecord]] {.base, async: (raises: [CancelledError]).} =
  var candidates = d.dhtMixProxies
  shuffle(candidates)

  for record in candidates:
    let proxy = record.data
    let res = await dht_proxy_client.lookupProviders(d.mixProto, proxy, cid)
    if res.isErr:
      warn "Mix lookup proxy failed", cid, proxy = proxy.peerId, err = res.error.msg
      continue
    return success res.get

  failure("All Mix lookup proxies failed (candidates=" & $candidates.len & ")")

method findDirect*(
    d: Discovery, cid: Cid
): Future[?!seq[SignedPeerRecord]] {.base, async: (raises: [CancelledError]).} =
  try:
    return (await d.protocol.getProviders(cid.toNodeId())).mapFailure
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Error finding providers for block " & $cid & ": " & exc.msg)

method find*(
    d: Discovery, cid: Cid
): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]), base.} =
  let providers =
    if d.privateQueries and not d.mixProto.isNil and d.dhtMixProxies.len > 0:
      (await d.findViaMix(cid)).valueOr:
        warn "Mix lookup failed", cid, err = error.msg
        return @[]
    else:
      (await d.findDirect(cid)).valueOr:
        warn "Direct lookup failed", cid, err = error.msg
        return @[]
  providers.filterIt(not (it.data.peerId == d.peerId))

method provide*(d: Discovery, cid: Cid) {.async: (raises: [CancelledError]), base.} =
  ## Provide a block Cid
  ##
  try:
    let nodes = await d.protocol.addProvider(cid.toNodeId(), d.providerRecord.get)

    if nodes.len <= 0:
      warn "Couldn't provide to any nodes!"
  except CancelledError as exc:
    warn "Error providing block", cid, exc = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error providing block", cid, exc = exc.msg

method find*(
    d: Discovery, host: ca.Address
): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]), base.} =
  ## Find host providers
  ##

  try:
    trace "Finding providers for host", host = $host
    without var providers =? (await d.protocol.getProviders(host.toNodeId())).mapFailure,
      error:
      trace "Error finding providers for host", host = $host, exc = error.msg
      return

    if providers.len <= 0:
      trace "No providers found", host = $host
      return

    providers.sort do(a, b: SignedPeerRecord) -> int:
      system.cmp[uint64](a.data.seqNo, b.data.seqNo)

    return providers
  except CancelledError as exc:
    warn "Error finding providers for host", host = $host, exc = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error finding providers for host", host = $host, exc = exc.msg

method provide*(
    d: Discovery, host: ca.Address
) {.async: (raises: [CancelledError]), base.} =
  ## Provide hosts
  ##

  try:
    trace "Providing host", host = $host
    let nodes = await d.protocol.addProvider(host.toNodeId(), d.providerRecord.get)
    if nodes.len > 0:
      trace "Provided to nodes", nodes = nodes.len
  except CancelledError as exc:
    warn "Error providing host", host = $host, exc = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error providing host", host = $host, exc = exc.msg

method removeProvider*(
    d: Discovery, peerId: PeerId
): Future[void] {.base, async: (raises: [CancelledError]).} =
  ## Remove provider from providers table
  ##

  trace "Removing provider", peerId
  try:
    await d.protocol.removeProvidersLocal(peerId)
  except CancelledError as exc:
    warn "Error removing provider", peerId = peerId, exc = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error removing provider", peerId = peerId, exc = exc.msg
  except Exception as exc: # Something in discv5 is raising Exception
    warn "Error removing provider", peerId = peerId, exc = exc.msg
    raiseAssert("Unexpected Exception in removeProvider")

proc getSpr*(d: Discovery): SignedPeerRecord =
  ## Expose the discovery addresses (UDP) and provider addresses (TCP).
  ## TCP addresses are needed because Autonat requires to connect to
  ## Autonat servers and we are currently using the provider record for that.
  ## We might get rid of that if we add a new configuration option that gives
  ## the Autonat servers the TCP addresses directly (as Mix options do), or
  ## once we get proper service discovery/migrate to the libp2p Kad DHT.
  return SignedPeerRecord
    .init(d.key, PeerRecord.init(d.peerId, d.providerAddrs & d.discoveryAddrs))
    .expect("Should construct signed record")

proc updateLocalMultiAddr(d: Discovery) =
  ## This is called when announce addresses change, to update the local Mix address
  ## when Autonat provides the dialable address in the callback.
  if d.mixProto.isNil:
    return

  let mixAddr = pickMixCompatibleMultiAddr(d.providerAddrs).valueOr:
    warn "No Mix-compatible address among announced addrs", addrs = d.providerAddrs
    mixUnsetMultiAddr()

  let res = d.mixProto.setLocalMultiAddr(mixAddr)
  if res.isErr:
    error "Failed to update Mix local address", address = mixAddr, err = res.error
  else:
    info "Mix local address updated", address = mixAddr

proc announceDirectAddrs*(
    d: Discovery, providerAddrs: openArray[MultiAddress], udpPort: Port
) =
  # UDP addresses are derived from TCP addresses by remapping protocol and port.
  let tcpAddrs = @providerAddrs
  let addrsChanged = tcpAddrs.len > 0 and tcpAddrs.sorted() != d.providerAddrs.sorted()
  let udpAddrs =
    tcpAddrs.mapIt(it.remapAddr(protocol = some("udp"), port = some(udpPort)))

  info "Updating provider and discovery records", tcpAddrs, udpAddrs

  d.providerAddrs = tcpAddrs
  d.providerRecord = SignedPeerRecord
    .init(d.key, PeerRecord.init(d.peerId, tcpAddrs))
    .expect("Should construct signed record").some

  info "Provider record updated",
    addrs = d.providerAddrs, spr = d.providerRecord.get.toURI

  d.discoveryAddrs = udpAddrs
  if not d.protocol.isNil:
    let spr = SignedPeerRecord
      .init(d.key, PeerRecord.init(d.peerId, udpAddrs))
      .expect("Should construct signed record").some
    d.protocol.updateRecord(spr).expect("Should update SPR")

  # Not gated on addrsChanged: clearing the announce must reset Mix too.
  d.updateLocalMultiAddr()

  if addrsChanged and not d.onAddrChange.isNil:
    d.onAddrChange()

proc announceRelayAddrs*(d: Discovery, addrs: openArray[MultiAddress]) =
  ## Updates the announce addresses and the SPR with the relay circuit addresses.
  ## Unlike announceDirectAddrs, no UDP address is derived so discoveryAddrs is left untouched.
  let addrsChanged = addrs.len > 0 and addrs.sorted() != d.providerAddrs.sorted()
  d.providerAddrs = @addrs

  info "Updating announce record", addrs = d.providerAddrs

  d.providerRecord = SignedPeerRecord
    .init(d.key, PeerRecord.init(d.peerId, d.providerAddrs))
    .expect("Should construct signed record").some

  info "Provider record updated",
    addrs = d.providerAddrs, spr = d.providerRecord.get.toURI

  d.updateLocalMultiAddr()

  if addrsChanged and not d.onAddrChange.isNil:
    d.onAddrChange()

proc start*(d: Discovery) {.async: (raises: []).} =
  try:
    d.protocol.open()
    await d.protocol.start()
    d.isStarted = true
  except CatchableError as exc:
    error "Error starting discovery", exc = exc.msg

proc stop*(d: Discovery) {.async: (raises: []).} =
  if not d.isStarted:
    warn "Discovery not started, skipping stop"
    return

  try:
    await noCancel d.protocol.closeWait()
    d.isStarted = false
    trace "Discovery stopped"
  except CatchableError as exc:
    error "Error stopping discovery", exc = exc.msg

proc close*(d: Discovery) {.async: (raises: []).} =
  if d.store.isNil:
    warn "Discovery store is nil, skipping close"
    return

  let res = await noCancel d.store.close()
  if res.isErr:
    error "Error closing discovery store", error = res.error().msg
  else:
    trace "Discovery store closed"

proc togglePrivateQueries*(d: Discovery, enabled: bool): ?!bool =
  if enabled and (d.mixProto.isNil or d.dhtMixProxies.len == 0):
    return failure("Cannot enable private queries: Mix is not configured")
  let old = d.privateQueries
  d.privateQueries = enabled
  success(old)

proc new*(
    T: type Discovery,
    key: PrivateKey,
    bindIp = IPv4_any(),
    bindPort = 0.Port,
    providerAddrs: openArray[MultiAddress] = [],
    discoveryPort = 0.Port,
    bootstrapNodes: openArray[SignedPeerRecord] = [],
    dhtMixProxies: openArray[SignedPeerRecord] = [],
    store: Datastore = SQLiteDatastore.new(Memory).expect("Should not fail!"),
    tableIpLimits: TableIpLimits = DefaultTableIpLimits,
): Discovery =
  ## Create a new Discovery node instance for the given key and datastore
  ##

  var self = Discovery(
    key: key,
    peerId: PeerId.init(key).expect("Should construct PeerId"),
    store: store,
    dhtMixProxies: @dhtMixProxies,
  )

  # Called even when providerAddrs is empty: newProtocol below requires
  # providerRecord to be set, and it will be updated with real addresses in start().
  self.announceDirectAddrs(providerAddrs, udpPort = discoveryPort)

  let discoveryConfig =
    DiscoveryConfig(tableIpLimits: tableIpLimits, bitsPerHop: DefaultBitsPerHop)

  self.protocol = newProtocol(
    key,
    bindIp = bindIp,
    bindPort = bindPort,
    record = self.providerRecord.get,
    bootstrapRecords = bootstrapNodes,
    rng = storage_rng.libp2pRng(storage_rng.Rng.instance()),
    providers = ProvidersManager.new(store),
    config = discoveryConfig,
  )

  self
