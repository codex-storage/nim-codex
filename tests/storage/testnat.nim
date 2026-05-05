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
import ../../storage/utils/addrutils

type MockNatMapper = ref object of NatMapper
  mappedPorts: Option[(Port, Port)]

method mapNatPorts*(m: MockNatMapper): Option[(Port, Port)] {.raises: [].} =
  m.mappedPorts

suite "remapAddr":
  test "replaces protocol tcp with udp":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(protocol = some("udp"), port = some(Port(9000)))
    check remapped == MultiAddress.init("/ip4/1.2.3.4/udp/9000").expect("valid")

  test "replaces only port, keeping protocol":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(port = some(Port(9000)))
    check remapped == MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")

  test "replaces only ip, keeping protocol and port":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(ip = some(parseIpAddress("8.8.8.8")))
    check remapped == MultiAddress.init("/ip4/8.8.8.8/tcp/5000").expect("valid")

suite "nattedPorts":
  test "returns none when extIp is configured (manual setup)":
    let natConfig = NatConfig(hasExtIp: true, extIp: parseIpAddress("8.8.8.8"))
    check nattedPorts(natConfig, Port(5000), Port(1234)).isNone

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

  let discoveryPort = Port(8090)

  test "handleNatStatus announces mapped address when NotReachable and UPnP succeeds":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatMapper(mappedPorts: some((Port(9000), Port(9001))))

    await handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, mapper, disc, sw, autoRelay
    )

    check disc.announceAddrs ==
      @[MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")]
    check not autoRelay.isRunning

  test "handleNatStatus starts autoRelay when NotReachable and UPnP failed":
    let mapper = MockNatMapper(mappedPorts: none((Port, Port)))

    await handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, mapper, disc, sw, autoRelay
    )

    check autoRelay.isRunning

  test "handleNatStatus does not announce address when Reachable and no dialBackAddr":
    let mapper = MockNatMapper(mappedPorts: none((Port, Port)))

    await handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, mapper, disc, sw, autoRelay
    )

    check disc.announceAddrs == newSeq[MultiAddress]()
    check not autoRelay.isRunning

  test "handleNatStatus stops relay and announces dialBackAddr when Reachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatMapper(mappedPorts: none((Port, Port)))

    discard await autorelayservice.setup(autoRelay, sw)
    await handleNatStatus(
      Reachable, Opt.some(dialBack), discoveryPort, mapper, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check disc.announceAddrs == @[dialBack]
