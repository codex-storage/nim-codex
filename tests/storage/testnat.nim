import std/net
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/libp2p/protocols/connectivity/autonatv2/service except setup
import pkg/libp2p/protocols/connectivity/autonatv2/types
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/services/autorelayservice except setup

import pkg/results

import ./helpers
import ../asynctest
import ../../storage/nat
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils
import ../../storage/utils/natutils

type MockNatMapper = ref object of NatMapper
  mapped: tuple[libp2p, discovery: seq[MultiAddress]]

method mapNatAddresses*(
    m: MockNatMapper, addrs: seq[MultiAddress]
): tuple[libp2p, discovery: seq[MultiAddress]] {.raises: [].} =
  m.mapped

method getReachableAddresses*(
    m: MockNatMapper, addrs: seq[MultiAddress]
): tuple[libp2p, discovery: seq[MultiAddress]] {.raises: [].} =
  m.mapped

suite "NAT Address Tests":
  test "nattedAddress with local addresses":
    # Setup test data
    let
      udpPort = Port(1234)
      natConfig = NatConfig(hasExtIp: true, extIp: parseIpAddress("8.8.8.8"))

      # Create test addresses
      localAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/5000").expect("valid multiaddr")
      anyAddr = MultiAddress.init("/ip4/0.0.0.0/tcp/5000").expect("valid multiaddr")
      publicAddr =
        MultiAddress.init("/ip4/192.168.1.1/tcp/5000").expect("valid multiaddr")

    # Expected results
    let
      expectedDiscoveryAddrs = @[
        MultiAddress.init("/ip4/8.8.8.8/udp/1234").expect("valid multiaddr"),
        MultiAddress.init("/ip4/8.8.8.8/udp/1234").expect("valid multiaddr"),
        MultiAddress.init("/ip4/8.8.8.8/udp/1234").expect("valid multiaddr"),
      ]
      expectedlibp2pAddrs = @[
        MultiAddress.init("/ip4/8.8.8.8/tcp/5000").expect("valid multiaddr"),
        MultiAddress.init("/ip4/8.8.8.8/tcp/5000").expect("valid multiaddr"),
        MultiAddress.init("/ip4/8.8.8.8/tcp/5000").expect("valid multiaddr"),
      ]
      #ipv6Addr = MultiAddress.init("/ip6/::1/tcp/5000").expect("valid multiaddr")
      addrs = @[localAddr, anyAddr, publicAddr]

    # Test address remapping
    let (libp2pAddrs, discoveryAddrs) = nattedAddress(natConfig, addrs, udpPort)

    # Verify results
    check(discoveryAddrs == expectedDiscoveryAddrs)
    check(libp2pAddrs == expectedlibp2pAddrs)

suite "setupAddress":
  test "public bind IP with NatNone returns bind IP":
    let
      bindIp = parseIpAddress("8.8.8.8")
      natConfig = NatConfig(hasExtIp: false, nat: NatStrategy.NatNone)
      (ip, tcpPort, udpPort) =
        setupAddress(natConfig, bindIp, Port(5000), Port(5001), "test")

    check ip == some(bindIp)
    check tcpPort == some(Port(5000))
    check udpPort == some(Port(5001))

  test "private bind IP with NatNone returns no IP":
    let
      bindIp = parseIpAddress("192.168.1.1")
      natConfig = NatConfig(hasExtIp: false, nat: NatStrategy.NatNone)
      (ip, tcpPort, udpPort) =
        setupAddress(natConfig, bindIp, Port(5000), Port(5001), "test")

    check ip == none(IpAddress)
    check tcpPort == some(Port(5000))
    check udpPort == some(Port(5001))

suite "getReachableAddresses":
  test "returns remapped addresses when extIp is configured":
    let
      natConfig = NatConfig(hasExtIp: true, extIp: parseIpAddress("1.2.3.4"))
      mapper = DefaultNatMapper(natConfig: natConfig, discoveryPort: Port(8090))
      listenAddr = MultiAddress.init("/ip4/0.0.0.0/tcp/5000").expect("valid")

    let (libp2pAddrs, discAddrs) = mapper.getReachableAddresses(@[listenAddr])

    check libp2pAddrs == @[MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")]
    check discAddrs == @[MultiAddress.init("/ip4/1.2.3.4/udp/8090").expect("valid")]

suite "hasPublicIp":
  test "hasPublicIp returns true when the address is public":
    let ma = MultiAddress.init("/ip4/8.8.8.8/tcp/8080").expect("valid")
    check hasPublicIp(@[ma])

  test "hasPublicIp returns false when the address is private":
    let ma = MultiAddress.init("/ip4/192.168.1.1/tcp/8080").expect("valid")
    check not hasPublicIp(@[ma])

  test "hasPublicIp returns false when the address is empty":
    check not hasPublicIp(@[])

asyncchecksuite "handleNatStatus":
  var sw: Switch
  var key: PrivateKey
  var disc: Discovery
  let autoRelay =
    AutoRelayService.new(1, relayClientModule.RelayClient.new(), nil, Rng.instance())

  setup:
    key = PrivateKey.random(Rng.instance[]).get()
    disc = Discovery.new(key, announceAddrs = @[])
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()

    if autoRelay.isRunning:
      discard await autoRelay.stop(sw)

  test "handleNatStatus announces address when the node is not Reachable and the UPnP succeed with public ip":
    let announceAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let discAddr = MultiAddress.init("/ip4/1.2.3.4/udp/8090").expect("valid")
    let mapper = MockNatMapper(mapped: (@[announceAddr], @[discAddr]))

    await handleNatStatus(NotReachable, mapper, disc, sw, autoRelay)

    check disc.announceAddrs == @[announceAddr]
    check not autoRelay.isRunning

  # test "handleNatStatus does not announce address when the node is not Reachable and the UPnP succeed with private ip":
  #   let privateAddr = MultiAddress.init("/ip4/192.168.1.1/tcp/8080").expect("valid")
  #   let mapper = MockNatMapper(mapped: (@[privateAddr], @[]))

  #   await handleNatStatus(
  #     NotReachable, mapper, disc, sw, autoRelay
  #   )

  #   check disc.announceAddrs == @[]
  #   check not autoRelay.isRunning

  test "handleNatStatus starts autoRelay when node is not Reachable and UPnP failed":
    let mapper = MockNatMapper(mapped: (@[], @[]))

    await handleNatStatus(NotReachable, mapper, disc, sw, autoRelay)

    check autoRelay.isRunning
    # The addresses will be announced in the onReservation callback
    # after a node accepted a Relay reservation.

  test "handleNatStatus does not announce address when node is Reachable and relay is not running":
    let mapper = MockNatMapper(mapped: (@[], @[]))

    await handleNatStatus(Reachable, mapper, disc, sw, autoRelay)

    check disc.announceAddrs == newSeq[MultiAddress]()
    check not autoRelay.isRunning

  test "handleNatStatus stops relay and announces address when node is Reachable and relay is running":
    let announceAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let discAddr = MultiAddress.init("/ip4/1.2.3.4/udp/8090").expect("valid")
    let mapper = MockNatMapper(mapped: (@[announceAddr], @[discAddr]))

    discard await autorelayservice.setup(autoRelay, sw)
    await handleNatStatus(Reachable, mapper, disc, sw, autoRelay)

    check not autoRelay.isRunning
    check disc.announceAddrs == @[announceAddr]
