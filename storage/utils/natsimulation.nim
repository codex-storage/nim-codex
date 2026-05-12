{.push raises: [].}

import std/sequtils
import pkg/chronos
import pkg/results
import pkg/libp2p
import pkg/libp2p/transports/tcptransport
import pkg/libp2p/transports/transport
import pkg/libp2p/wire

type FilteringBehavior* = enum
  EndpointIndependent
  AddressDependent
  AddressAndPortDependent

type NatRouter* = ref object
  filtering*: FilteringBehavior
  conntrack: seq[TransportAddress]

type NatTransport* = ref object of Transport
  tcp: TcpTransport
  router: NatRouter

proc fromString*(T: type FilteringBehavior, s: string): Result[FilteringBehavior, string] =
  case s
  of "endpoint-independent": ok(EndpointIndependent)
  of "address-dependent": ok(AddressDependent)
  of "address-and-port-dependent": ok(AddressAndPortDependent)
  else: err("Unknown filtering behavior: " & s)

proc new*(T: type NatRouter, filtering: FilteringBehavior): T =
  T(filtering: filtering)

proc setFiltering*(r: NatRouter, filtering: FilteringBehavior) =
  r.filtering = filtering
  r.conntrack = @[]

proc allowInbound(r: NatRouter, remote: TransportAddress): bool =
  case r.filtering
  of EndpointIndependent:
    true
  of AddressDependent:
    r.conntrack.anyIt(
      try:
        it.address == remote.address
      except ValueError:
        false
    )
  of AddressAndPortDependent:
    remote in r.conntrack

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

proc dropAfterTimeout(conn: Connection) {.async: (raises: []).} =
  # Hold the connection open long enough for the remote's dial to time out,
  # then close it. This simulates a NAT that drops packets rather than RSTs
  # them, which is what AutoNAT needs to detect NotReachable.
  await noCancel sleepAsync(20.seconds)
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

    if not self.router.allowInbound(transportAddr.get):
      # Do not close immediately: let the remote's dial time out naturally,
      # then clean up. Returning a fast RST would produce EDialRefused (Unknown)
      # instead of EDialError (NotReachable) in AutoNAT.
      asyncSpawn dropAfterTimeout(conn)
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
