import std/[net]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/libp2p/protocols/connectivity/autonat/types
import pkg/libp2p/protocols/connectivity/autonatv2/service except setup
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/services/autorelayservice except setup
import pkg/results

import ./helpers
import ../asynctest
import ../../storage/utils/natutils
import ../../storage/nat
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils

type MockNatPortMapper = ref object of NatPortMapper
  mappedPorts: Option[(Port, Port, MappingProtocol)]
  activeMapping: bool

method mapNatPorts*(
    m: MockNatPortMapper
): Future[Option[(Port, Port, MappingProtocol)]] {.
    async: (raises: [CancelledError]), gcsafe
.} =
  m.mappedPorts

method hasMappingIds*(m: MockNatPortMapper): bool =
  m.activeMapping

asyncchecksuite "NAT reaction - port mapping":
  var sw: Switch
  var key: PrivateKey
  var disc: Discovery
  var autoRelay: AutoRelayService

  setup:
    autoRelay =
      AutoRelayService.new(1, relayClientModule.RelayClient.new(), nil, Rng.instance())
    key = PrivateKey.random(Rng.instance()).get()
    disc = Discovery.new(key, announceAddrs = @[])
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()

    if autoRelay.isRunning:
      await autoRelay.stop(sw)

  let discoveryPort = Port(8090)

  test "handleNatStatus announces mapped address when NotReachable and UPnP succeeds":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(
      mappedPorts: some((Port(9000), Port(9001), MappingProtocol.UPnP))
    )

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check disc.announceAddrs ==
      @[MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")]
    check not autoRelay.isRunning
    check disc.protocol.clientMode

  test "handleNatStatus starts autoRelay when NotReachable and no dialBackAddr but no mapped ports":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.protocol.clientMode

  test "handleNatStatus starts autoRelay when NotReachable and dialBackAddr but no mapped ports":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus tears down an active mapping and starts relay when NotReachable with dialBackAddr":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(activeMapping: true)

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus tears down an active mapping and starts relay when NotReachable without dialBackAddr":
    let mapper = MockNatPortMapper(activeMapping: true)

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus stops relay and exits client mode when mapping is created and node is Reachable":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    disc.protocol.clientMode = true
    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check not disc.protocol.clientMode

  test "handleNatStatus does nothing after the mapper is stopped":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(
      mappedPorts: some((Port(9000), Port(9001), MappingProtocol.UPnP))
    )
    mapper.stop()

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()

asyncchecksuite "NAT reaction - address announcing":
  var sw: Switch
  var key: PrivateKey
  var disc: Discovery

  setup:
    key = PrivateKey.random(Rng.instance()).get()
    disc = Discovery.new(key, announceAddrs = @[])
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()

  let discoveryPort = Port(8090)

  test "announcePeerInfoAddrs excludes relay circuit addresses":
    let circuitAddr = MultiAddress
      .init("/ip4/1.2.3.4/tcp/4040/p2p/" & $sw.peerInfo.peerId & "/p2p-circuit")
      .expect("valid")
    sw.peerInfo.addrs.add(circuitAddr)

    announcePeerInfoAddrs(disc, sw.peerInfo, discoveryPort)

    check circuitAddr notin disc.announceAddrs
    check disc.announceAddrs == sw.peerInfo.addrs.filterIt(it != circuitAddr)

  test "announcePeerInfoAddrs does nothing when addresses are already announced":
    announcePeerInfoAddrs(disc, sw.peerInfo, discoveryPort)
    let seqNo = disc.getSpr().data.seqNo

    announcePeerInfoAddrs(disc, sw.peerInfo, discoveryPort)

    check disc.getSpr().data.seqNo == seqNo

  test "peerInfo observer announces addresses when Reachable":
    let autonat = AutonatV2Service.new(Rng.instance())
    discard setupPeerInfoObserver(
      sw, autonat, disc, NatPortMapper(discoveryPort: discoveryPort)
    )
    autonat.networkReachability = Reachable

    sw.peerInfo.listenAddrs.add(
      MultiAddress.init("/ip4/1.2.3.4/tcp/9999").expect("valid")
    )
    await sw.peerInfo.update()

    check disc.announceAddrs == sw.peerInfo.addrs

  test "peerInfo observer announces the mapped external UDP port when a mapping is active":
    let autonat = AutonatV2Service.new(Rng.instance())
    let mapper =
      NatPortMapper(discoveryPort: discoveryPort, activeUdpPort: some(Port(40001)))
    discard setupPeerInfoObserver(sw, autonat, disc, mapper)
    autonat.networkReachability = Reachable

    sw.peerInfo.listenAddrs.add(
      MultiAddress.init("/ip4/1.2.3.4/tcp/9999").expect("valid")
    )
    await sw.peerInfo.update()

    let sprAddrs = disc.getSpr().data.addresses.mapIt(it.address)
    check MultiAddress.init("/ip4/1.2.3.4/udp/40001").expect("valid") in sprAddrs
    check MultiAddress.init("/ip4/1.2.3.4/udp/" & $discoveryPort).expect("valid") notin
      sprAddrs

  test "peerInfo observer does not announce when the node is not Reachable":
    let autonat = AutonatV2Service.new(Rng.instance())
    discard setupPeerInfoObserver(
      sw, autonat, disc, NatPortMapper(discoveryPort: discoveryPort)
    )
    autonat.networkReachability = NotReachable

    sw.peerInfo.listenAddrs.add(
      MultiAddress.init("/ip4/1.2.3.4/tcp/9999").expect("valid")
    )
    await sw.peerInfo.update()

    check disc.announceAddrs == newSeq[MultiAddress]()
