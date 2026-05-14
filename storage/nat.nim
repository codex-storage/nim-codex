# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[options, net]
import results

import pkg/chronos
import pkg/chronos/threadsync
import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/services/autorelayservice

import ./utils
import ./utils/natutils
import ./utils/addrutils
import ./discovery

logScope:
  topics = "nat"

const NatPortMappingTimeout = 5.seconds

type NatConfig* = object
  case hasExtIp*: bool
  of true: extIp*: IpAddress
  of false: nat*: NatStrategy

type PortMappingType* = enum
  NoMapping
  UpnpMapping
  PmpMapping

type NatMapper* = ref object of RootObj
  natConfig*: NatConfig
  tcpPort*: Port
  discoveryPort*: Port
  portMappingType*: PortMappingType

type MapNatPortsCtx = object
  natConfig: NatConfig
  tcpPort: Port
  discoveryPort: Port
  signal: ThreadSignalPtr
  result: Option[(Port, Port)]
  portMappingType: PortMappingType

proc mapNatPortsThread(ctx: ptr MapNatPortsCtx) {.thread.} =
  if ctx.natConfig.hasExtIp:
    discard ctx.signal.fireSync()
    return

  # Devices are recreated on each call: discover() costs ~200ms but only fires
  # when AutoNAT reports NotReachable, which is exactly when we want a fresh scan.
  let upnpRes = UpnpDevice.init()
  if upnpRes.isOk:
    let ports = upnpRes.value.mapPorts(ctx.tcpPort, ctx.discoveryPort)
    if ports.isSome:
      ctx.portMappingType = UpnpMapping
      ctx.result = ports
      discard ctx.signal.fireSync()
      return

  let pmpRes = PmpDevice.init()
  if pmpRes.isOk:
    let ports = pmpRes.value.mapPorts(ctx.tcpPort, ctx.discoveryPort)
    if ports.isSome:
      ctx.portMappingType = PmpMapping
      ctx.result = ports

  discard ctx.signal.fireSync()

method mapNatPorts*(
    m: NatMapper
): Future[Option[(Port, Port)]] {.async: (raises: [CancelledError]), base, gcsafe.} =
  let signal = ThreadSignalPtr.new().valueOr:
    warn "Failed to create ThreadSignalPtr for NAT port mapping"
    return none((Port, Port))

  var ctx = cast[ptr MapNatPortsCtx](createShared(MapNatPortsCtx))
  ctx[] = MapNatPortsCtx(
    natConfig: m.natConfig,
    tcpPort: m.tcpPort,
    discoveryPort: m.discoveryPort,
    signal: signal,
  )

  var thread: Thread[ptr MapNatPortsCtx]
  var threadStarted = false
  defer:
    if threadStarted:
      # Blocking the event loop here is acceptable: UPnP discover() is bounded
      # by UPNP_TIMEOUT (200ms), so the worst-case stall is ~200ms.
      joinThread(thread)
      # Always sync hasUpnpMapping back, even on timeout or cancellation.
      # If the thread mapped ports just after the timeout, close() will
      # still clean them up on the router.
      if ctx.portMappingType != NoMapping:
        m.portMappingType = ctx.portMappingType
    freeShared(ctx)
    discard signal.close()

  try:
    createThread(thread, mapNatPortsThread, ctx)
    threadStarted = true
  except ValueError, ResourceExhaustedError:
    warn "Failed to create thread for NAT port mapping"
    return none((Port, Port))

  try:
    if not await signal.wait().withTimeout(NatPortMappingTimeout):
      warn "NAT port mapping thread timed out"
      return none((Port, Port))
  except CancelledError as exc:
    raise exc
  except AsyncError as exc:
    warn "Error waiting for NAT port mapping thread", error = exc.msg
    return none((Port, Port))

  return ctx.result

method handleNatStatus*(
    m: NatMapper,
    networkReachability: NetworkReachability,
    dialBackAddr: Opt[MultiAddress],
    discoveryPort: Port,
    discovery: Discovery,
    switch: Switch,
    autoRelayService: AutoRelayService,
) {.async: (raises: [CancelledError]), base, gcsafe.} =
  case networkReachability
  of Unknown:
    discard
  of Reachable:
    if dialBackAddr.isNone:
      warn "Got empty dialback address in AutoNat when node is Reachable"
      return

    if autoRelayService.isRunning:
      if not await autoRelayService.stop(switch):
        debug "AutoRelayService stop method returned false"
      else:
        debug "AutoRelayService stopped"

    discovery.updateRecords(@[dialBackAddr.get], udpPort = discoveryPort)
    discovery.protocol.clientMode = false
  of NotReachable:
    var hasPortMapping = false

    discovery.protocol.clientMode = true

    if dialBackAddr.isNone:
      warn "Got empty dialback address in AutoNat when node is NotReachable"
    else:
      debug "Node is not reachable trying UPnP / PMP now"

      # Here we should check first that a mapping exists.
      # If it does exist but Autonat still report as Not Reachable
      # we should fallback to relay.
      let maybePorts = await m.mapNatPorts()

      if maybePorts.isSome:
        let (tcpPort, udpPort) = maybePorts.get()

        info "Port mapping created successfully", tcpPort, udpPort

        let announceAddress = dialBackAddr.get.remapAddr(port = some(tcpPort))

        if autoRelayService.isRunning:
          # Here we stop the relay because the node *should* be reachable
          if not await autoRelayService.stop(switch):
            debug "AutoRelayService stop method returned false"
          else:
            debug "AutoRelayService stopped"

        # Note that we update the DHT records but we don't set the client mode
        # to false because we are not sure the node is reachable.
        # The client mode will be updated on the next iteration of autonat.
        # Trying to check manually that the node is reachable is not trivial,
        # this is exactly what Autonat does.
        discovery.updateRecords(@[announceAddress], udpPort = udpPort)
        hasPortMapping = true

    if not hasPortMapping and not autoRelayService.isRunning:
      debug "No port mapping found let's start autorelay"

      if not await autoRelayService.setup(switch):
        warn "Cannot start autorelay service"
      else:
        debug "AutoRelayService started"

proc close*(m: NatMapper, device = UpnpDevice()) =
  # UPnP mappings are permanent (leaseDuration=0) and must be deleted explicitly.
  # NAT-PMP mappings expire automatically after NATPMP_LIFETIME seconds.
  if m.portMappingType != UpnpMapping:
    return

  # deletePortMapping requires the IGD control URL set during init
  let deviceRes = device.init()
  if deviceRes.isErr:
    warn "UPnP reinit failed during cleanup, port mappings may remain",
      msg = deviceRes.error
    return

  for (port, proto) in [
    (m.tcpPort, NatIpProtocol.Tcp), (m.discoveryPort, NatIpProtocol.Udp)
  ]:
    let res = deviceRes.value.deletePortMapping(port, proto)
    if res.isErr:
      error "UPnP port mapping deletion failed", port, proto, msg = res.error

proc findReachableNodes*(bootstrapNodes: seq[SignedPeerRecord]): seq[SignedPeerRecord] =
  ## Returns the list of nodes known to be directly reachable.
  ## Currently returns bootstrap nodes. In the future, any network participant
  ## confirmed reachable by AutoNAT could be included.
  bootstrapNodes
