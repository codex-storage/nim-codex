{.push raises: [].}

import std/[options, sequtils]
import pkg/chronos
import pkg/results
import pkg/libp2p
import pkg/libp2p/transports/tcptransport
import pkg/libp2p/transports/transport
import pkg/libp2p/wire

import ../nat

type FilteringBehavior* = enum
  EndpointIndependent
  AddressDependent
  AddressAndPortDependent
  DoubleNat

type NatRouter* = ref object
  filtering*: FilteringBehavior
  conntrack: seq[TransportAddress]
  natMapper*: Option[NatPortMapper]
  dropTimeout*: Duration

type NatTransport* = ref object of Transport
  tcp: TcpTransport
  router: NatRouter

proc fromString*(
    T: type FilteringBehavior, s: string
): Result[FilteringBehavior, string] =
  case s
  of "endpoint-independent":
    ok(EndpointIndependent)
  of "address-dependent":
    ok(AddressDependent)
  of "address-and-port-dependent":
    ok(AddressAndPortDependent)
  of "double-nat":
    ok(DoubleNat)
  else:
    err("Unknown filtering behavior: " & s)

proc new*(
    T: type NatRouter, filtering: FilteringBehavior, dropTimeout = 20.seconds
): T =
  T(filtering: filtering, dropTimeout: dropTimeout)

proc setFiltering*(r: NatRouter, filtering: FilteringBehavior) =
  r.filtering = filtering
  r.conntrack = @[]

proc allowInbound(r: NatRouter, remote: TransportAddress, localPort: Port): bool =
  case r.filtering
  of DoubleNat:
    return false
  of EndpointIndependent:
    return true
  else:
    discard

  if r.natMapper.isSome and r.natMapper.get.isPortMapped(localPort):
    return true

  case r.filtering
  of AddressDependent:
    r.conntrack.anyIt(
      try:
        it.address == remote.address
      except ValueError:
        false
    )
  of AddressAndPortDependent:
    remote in r.conntrack
  else:
    false

proc new*(
    T: type NatTransport,
    router: NatRouter,
    upgrade: Upgrade,
    flags: set[ServerFlags] = {},
): T =
  let self = T(tcp: TcpTransport.new(flags, upgrade), upgrader: upgrade, router: router)
  procCall Transport(self).initialize()
  return self

method start*(
    self: NatTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  await self.tcp.start(addrs)
  self.addrs = self.tcp.addrs
  self.running = true
  self.onRunning.fire()

method stop*(self: NatTransport) {.async: (raises: []).} =
  await self.tcp.stop()
  self.running = false
  self.onStop.fire()

method dial*(
    self: NatTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  ## establishes an outgoing TCP connection and records the remote address
  ## so it can connect back to us later
  let conn = await self.tcp.dial(hostname, address)

  if conn.observedAddr.isSome:
    let transportAddr = initTAddress(conn.observedAddr.get)
    if transportAddr.isOk:
      self.router.conntrack.add(transportAddr.get)

  return conn

proc dropAfterTimeout(conn: Connection, timeout: Duration) {.async: (raises: []).} =
  # Hold the connection open long enough for the remote's dial to time out,
  # then close it. This simulates a NAT that drops packets rather than RSTs
  # them, which is what AutoNAT needs to detect NotReachable.
  await noCancel sleepAsync(timeout)
  await noCancel conn.close()

method accept*(
    self: NatTransport
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  ## waits for an incoming TCP connection and applies the NAT filtering rules
  while true:
    let conn = await self.tcp.accept()

    if self.router.filtering == EndpointIndependent:
      return conn

    if conn.observedAddr.isNone:
      await conn.close()
      continue

    let transportAddr = initTAddress(conn.observedAddr.get)
    if transportAddr.isErr:
      await conn.close()
      continue

    var localPort = Port(0)
    if self.addrs.len > 0:
      let localAddr = initTAddress(self.addrs[0])
      if localAddr.isOk:
        localPort = localAddr.get.port

    if not self.router.allowInbound(transportAddr.get, localPort):
      # Do not close immediately: let the remote's dial time out naturally,
      # then clean up. Returning a fast RST would produce EDialRefused (Unknown)
      # instead of EDialError (NotReachable) in AutoNAT.
      asyncSpawn dropAfterTimeout(conn, self.router.dropTimeout)
      continue

    return conn

method handles*(
    self: NatTransport, address: MultiAddress
): bool {.gcsafe, raises: [].} =
  ## returns true if this transport handles the given address (TCP only)
  if procCall Transport(self).handles(address):
    if address.protocols.isOk:
      return TCP.match(address)

proc withNatTransport*(
    b: SwitchBuilder, router: NatRouter, flags: set[ServerFlags] = {}
): SwitchBuilder =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      NatTransport.new(router, config.upgr, flags)
  )
