# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[options, os, times, atomics, exitprocs],
  nat_traversal/[miniupnpc, natpmp],
  results

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/protocols/connectivity/autonat/types
import pkg/libp2p/services/autorelayservice

import ./utils
import ./utils/natutils
import ./utils/addrutils
import ./discovery

const
  UPNP_TIMEOUT = 200 # ms
  PORT_MAPPING_INTERVAL = 20 * 60 # seconds
  NATPMP_LIFETIME = 60 * 60 # in seconds, must be longer than PORT_MAPPING_INTERVAL

type PortMappings* = object
  internalTcpPort: Port
  externalTcpPort: Port
  internalUdpPort: Port
  externalUdpPort: Port
  description: string

type PortMappingArgs =
  tuple[strategy: NatStrategy, tcpPort, udpPort: Port, description: string]

type NatConfig* = object
  case hasExtIp*: bool
  of true: extIp*: IpAddress
  of false: nat*: NatStrategy

var
  upnp {.threadvar.}: Miniupnp
  npmp {.threadvar.}: NatPmp
  strategy = NatStrategy.NatAuto
  natClosed: Atomic[bool]
  activeMappings: seq[PortMappings]
  natThreads: seq[Thread[PortMappingArgs]] = @[]

logScope:
  topics = "nat"

type NatMapper* = ref object of RootObj

method mapNatPorts*(m: NatMapper): Option[(Port, Port)] {.base, gcsafe, raises: [].} =
  raiseAssert "mapNatPorts not implemented"

type DefaultNatMapper* = ref object of NatMapper
  natConfig*: NatConfig
  tcpPort*: Port
  discoveryPort*: Port

## Initialises the UPnP or NAT-PMP threadvar and sets the `strategy` threadvar.
## Must be called before redirectPorts() in each thread.
proc initNatDevice(natStrategy: NatStrategy, quiet = false): bool =
  if natStrategy == NatStrategy.NatAuto or natStrategy == NatStrategy.NatUpnp:
    if upnp == nil:
      upnp = newMiniupnp()

    upnp.discoverDelay = UPNP_TIMEOUT
    let dres = upnp.discover()
    if dres.isErr:
      debug "UPnP", msg = dres.error
    else:
      var
        msg: cstring
        canContinue = true
      case upnp.selectIGD()
      of IGDNotFound:
        msg = "Internet Gateway Device not found. Giving up."
        canContinue = false
      of IGDFound:
        msg = "Internet Gateway Device found."
      of IGDNotConnected:
        msg = "Internet Gateway Device found but it's not connected. Trying anyway."
      of NotAnIGD:
        msg =
          "Some device found, but it's not recognised as an Internet Gateway Device. Trying anyway."
      of IGDIpNotRoutable:
        msg =
          "Internet Gateway Device found and is connected, but with a reserved or non-routable IP. Trying anyway."
      if not quiet:
        debug "UPnP", msg
      if canContinue:
        strategy = NatStrategy.NatUpnp
        return true

  if natStrategy == NatStrategy.NatAuto or natStrategy == NatStrategy.NatPmp:
    if npmp == nil:
      npmp = newNatPmp()
    let nres = npmp.init()
    if nres.isErr:
      debug "NAT-PMP", msg = nres.error
    else:
      strategy = NatStrategy.NatPmp
      return true

  return false

proc doPortMapping(
    strategy: NatStrategy, tcpPort, udpPort: Port, description: string
): Option[(Port, Port)] {.gcsafe.} =
  var
    extTcpPort: Port
    extUdpPort: Port

  if strategy == NatStrategy.NatUpnp:
    for t in [(tcpPort, UPNPProtocol.TCP), (udpPort, UPNPProtocol.UDP)]:
      let
        (port, protocol) = t
        pmres = upnp.addPortMapping(
          externalPort = $port,
          protocol = protocol,
          internalHost = upnp.lanAddr,
          internalPort = $port,
          desc = description,
          leaseDuration = 0,
        )
      if pmres.isErr:
        error "UPnP port mapping", msg = pmres.error, port
        return
      else:
        # let's check it
        let cres =
          upnp.getSpecificPortMapping(externalPort = $port, protocol = protocol)
        if cres.isErr:
          warn "UPnP port mapping check failed. Assuming the check itself is broken and the port mapping was done.",
            msg = cres.error

        info "UPnP: added port mapping",
          externalPort = port, internalPort = port, protocol = protocol
        case protocol
        of UPNPProtocol.TCP:
          extTcpPort = port
        of UPNPProtocol.UDP:
          extUdpPort = port
  elif strategy == NatStrategy.NatPmp:
    for t in [(tcpPort, NatPmpProtocol.TCP), (udpPort, NatPmpProtocol.UDP)]:
      let
        (port, protocol) = t
        pmres = npmp.addPortMapping(
          eport = port.cushort,
          iport = port.cushort,
          protocol = protocol,
          lifetime = NATPMP_LIFETIME,
        )
      if pmres.isErr:
        error "NAT-PMP port mapping", msg = pmres.error, port
        return
      else:
        let extPort = Port(pmres.value)
        info "NAT-PMP: added port mapping",
          externalPort = extPort, internalPort = port, protocol = protocol
        case protocol
        of NatPmpProtocol.TCP:
          extTcpPort = extPort
        of NatPmpProtocol.UDP:
          extUdpPort = extPort
  return some((extTcpPort, extUdpPort))

proc repeatPortMapping(args: PortMappingArgs) {.thread, raises: [ValueError].} =
  ignoreSignalsInThread()
  let
    (strategy, tcpPort, udpPort, description) = args
    interval = initDuration(seconds = PORT_MAPPING_INTERVAL)
    sleepDuration = 1_000 # in ms, also the maximum delay after pressing Ctrl-C

  var lastUpdate = now()

  # We can't use copies of Miniupnp and NatPmp objects in this thread, because they share
  # C pointers with other instances that have already been garbage collected, so
  # we use threadvars instead and initialise them again here.
  if initNatDevice(strategy, quiet = true):
    while natClosed.load() == false:
      let currTime = now()
      if currTime >= (lastUpdate + interval):
        discard doPortMapping(strategy, tcpPort, udpPort, description)
        lastUpdate = currTime

      sleep(sleepDuration)

proc stopNatThreads() {.noconv.} =
  # stop the thread
  debug "Stopping NAT port mapping renewal threads"
  try:
    natClosed.store(true)
    joinThreads(natThreads)
  except Exception as exc:
    warn "Failed to stop NAT port mapping renewal thread", exc = exc.msg

  # delete our port mappings

  # FIXME: if the initial port mapping failed because it already existed for the
  # required external port, we should not delete it. It might have been set up
  # by another program.

  # In Windows, a new thread is created for the signal handler, so we need to
  # initialise our threadvars again.

  if initNatDevice(strategy, quiet = true):
    if strategy == NatStrategy.NatUpnp:
      for entry in activeMappings:
        for t in [
          (entry.externalTcpPort, entry.internalTcpPort, UPNPProtocol.TCP),
          (entry.externalUdpPort, entry.internalUdpPort, UPNPProtocol.UDP),
        ]:
          let
            (eport, iport, protocol) = t
            pmres = upnp.deletePortMapping(externalPort = $eport, protocol = protocol)
          if pmres.isErr:
            error "UPnP port mapping deletion", msg = pmres.error
          else:
            debug "UPnP: deleted port mapping",
              externalPort = eport, internalPort = iport, protocol = protocol
    elif strategy == NatStrategy.NatPmp:
      for entry in activeMappings:
        for t in [
          (entry.externalTcpPort, entry.internalTcpPort, NatPmpProtocol.TCP),
          (entry.externalUdpPort, entry.internalUdpPort, NatPmpProtocol.UDP),
        ]:
          let
            (eport, iport, protocol) = t
            pmres = npmp.deletePortMapping(
              eport = eport.cushort, iport = iport.cushort, protocol = protocol
            )
          if pmres.isErr:
            error "NAT-PMP port mapping deletion", msg = pmres.error
          else:
            debug "NAT-PMP: deleted port mapping",
              externalPort = eport, internalPort = iport, protocol = protocol

proc redirectPorts*(
    strategy: NatStrategy, tcpPort, udpPort: Port, description: string
): Option[(Port, Port)] =
  result = doPortMapping(strategy, tcpPort, udpPort, description)
  if result.isSome:
    let (externalTcpPort, externalUdpPort) = result.get()
    # needed by NAT-PMP on port mapping deletion
    # Port mapping works. Let's launch a thread that repeats it, in case the
    # NAT-PMP lease expires or the router is rebooted and forgets all about
    # these mappings.
    activeMappings.add(
      PortMappings(
        internalTcpPort: tcpPort,
        externalTcpPort: externalTcpPort,
        internalUdpPort: udpPort,
        externalUdpPort: externalUdpPort,
        description: description,
      )
    )
    try:
      natThreads.add(Thread[PortMappingArgs]())
      natThreads[^1].createThread(
        repeatPortMapping, (strategy, externalTcpPort, externalUdpPort, description)
      )
      # atexit() in disguise
      if natThreads.len == 1:
        # we should register the thread termination function only once
        addExitProc(stopNatThreads)
    except Exception as exc:
      warn "Failed to create NAT port mapping renewal thread", exc = exc.msg

proc setupNat*(
    natStrategy: NatStrategy, tcpPort, udpPort: Port, clientId: string
): Option[(Port, Port)] =
  ## Setup NAT port mapping.
  ## Returns the external (tcpPort, udpPort) if port mapping succeeded, none otherwise.
  ## TODO: Allow for tcp or udp port mapping to be optional.
  if not initNatDevice(natStrategy):
    warn "UPnP/NAT-PMP not available"
    return none((Port, Port))

  let extPorts = (
    {.gcsafe.}:
      redirectPorts(
        strategy, tcpPort = tcpPort, udpPort = udpPort, description = clientId
      )
  )
  if extPorts.isNone:
    warn "UPnP/NAT-PMP available but port forwarding failed"
  extPorts

proc findReachableNodes*(bootstrapNodes: seq[SignedPeerRecord]): seq[SignedPeerRecord] =
  ## Returns the list of nodes known to be directly reachable.
  ## Currently returns bootstrap nodes. In the future, any network participant
  ## confirmed reachable by AutoNAT could be included.
  bootstrapNodes

proc nattedPorts*(natConfig: NatConfig, tcpPort, udpPort: Port): Option[(Port, Port)] =
  if natConfig.hasExtIp:
    return none((Port, Port)) # manual setup, no port mapping needed
  setupNat(natConfig.nat, tcpPort, udpPort, "storage")

method mapNatPorts*(m: DefaultNatMapper): Option[(Port, Port)] {.gcsafe, raises: [].} =
  nattedPorts(m.natConfig, m.tcpPort, m.discoveryPort)

proc hasPublicIp*(addrs: seq[MultiAddress]): bool =
  for addr in addrs:
    let (ip, _) = getAddressAndPort(addr)
    if ip.isSome and isGlobalUnicast(ip.get):
      return true

proc handleNatStatus*(
    networkReachability: NetworkReachability,
    dialBackAddr: Opt[MultiAddress],
    discoveryPort: Port,
    mapper: NatMapper,
    discovery: Discovery,
    switch: Switch,
    autoRelayService: AutoRelayService,
) {.async: (raises: [CancelledError]).} =
  case networkReachability
  of Unknown:
    # Nothing to do here, not enough confidence score result
    discard
  of Reachable:
    if dialBackAddr.isNone:
      warn "Got empty dialback address in AutoNat when node is Reachable"
      return

    if autoRelayService.isRunning:
      if not await autoRelayService.stop(switch):
        debug "AutoRelayService stop method returned false"

    let discAddr =
      dialBackAddr.get.remapAddr(protocol = some("udp"), port = some(discoveryPort))
    discovery.updateAnnounceRecord(@[dialBackAddr.get])
    discovery.updateDhtRecord(@[dialBackAddr.get, discAddr])
    # TODO: switch DHT to server mode
  of NotReachable:
    var hasPortMapping = false

    if dialBackAddr.isSome:
      let maybePorts = mapper.mapNatPorts()

      if maybePorts.isSome:
        let (tcpPort, udpPort) = maybePorts.get()
        let announceAddr = dialBackAddr.get.remapAddr(port = some(tcpPort))
        let discAddr =
          dialBackAddr.get.remapAddr(protocol = some("udp"), port = some(udpPort))

        # TODO: Try a dial me to make sure we are reachable

        if autoRelayService.isRunning:
          if not await autoRelayService.stop(switch):
            debug "AutoRelayService stop method returned false"

        discovery.updateAnnounceRecord(@[announceAddr])
        discovery.updateDhtRecord(@[announceAddr, discAddr])

        hasPortMapping = true

    if not hasPortMapping and not autoRelayService.isRunning:
      if not await autoRelayService.setup(switch):
        debug "AutoRelayService setup method returned false"
