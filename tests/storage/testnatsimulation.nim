import std/net
import pkg/chronos
import pkg/libp2p/wire

import ./helpers
import ../asynctest
import ../../storage/rng
import ../../storage/nat
import ../../storage/utils/natsimulation

const flags = {ServerFlags.ReuseAddr}
const listenAddr = "/ip4/127.0.0.1/tcp/0"
const filterTimeout = 500.millis

proc cannotConnect(a, b: Switch): Future[bool] {.async.} =
  let completed =
    try:
      await a.connect(b.peerInfo.peerId, b.peerInfo.addrs).withTimeout(filterTimeout)
    except LPError:
      false
  if completed:
    return false
  return not a.isConnected(b.peerInfo.peerId)

proc newSwitch(rng: Rng): Switch =
  SwitchBuilder
    .new()
    .withRng(rng)
    .withPrivateKey(PrivateKey.random(rng).get())
    .withAddresses(@[MultiAddress.init(listenAddr).get()])
    .withTcpTransport(flags)
    .withNoise()
    .withYamux()
    .build()

proc newNatSwitch(router: NatRouter, rng: Rng): Switch =
  SwitchBuilder
    .new()
    .withRng(rng)
    .withPrivateKey(PrivateKey.random(rng).get())
    .withAddresses(@[MultiAddress.init(listenAddr).get()])
    .withNatTransport(router, flags)
    .withNoise()
    .withYamux()
    .build()

asyncchecksuite "NatTransport - Endpoint-Independent Filtering":
  var bootstrap, natNode: Switch

  setup:
    let router = NatRouter.new(EndpointIndependent)
    bootstrap = newSwitch(Rng.instance())
    natNode = newNatSwitch(router, Rng.instance())
    await bootstrap.start()
    await natNode.start()

  teardown:
    await bootstrap.stop()
    await natNode.stop()

  test "bootstrap can connect to nat node without any prior outbound":
    await bootstrap.connect(natNode.peerInfo.peerId, natNode.peerInfo.addrs)
    check bootstrap.isConnected(natNode.peerInfo.peerId)

asyncchecksuite "NatTransport - Address-Dependent Filtering":
  var bootstrap, thirdNode, natNode: Switch

  setup:
    let router = NatRouter.new(AddressDependent)
    bootstrap = newSwitch(Rng.instance())
    thirdNode = newSwitch(Rng.instance())
    natNode = newNatSwitch(router, Rng.instance())
    await bootstrap.start()
    await thirdNode.start()
    await natNode.start()

  teardown:
    await bootstrap.stop()
    await thirdNode.stop()
    await natNode.stop()

  test "bootstrap can connect to nat node with a pre-existing connection":
    await natNode.connect(bootstrap.peerInfo.peerId, bootstrap.peerInfo.addrs)
    check natNode.isConnected(bootstrap.peerInfo.peerId)

    await bootstrap.connect(natNode.peerInfo.peerId, natNode.peerInfo.addrs)
    check bootstrap.isConnected(natNode.peerInfo.peerId)

  test "third node can connect to nat node after nat node connected to bootstrap":
    await natNode.connect(bootstrap.peerInfo.peerId, bootstrap.peerInfo.addrs)
    await thirdNode.connect(natNode.peerInfo.peerId, natNode.peerInfo.addrs)
    check thirdNode.isConnected(natNode.peerInfo.peerId)

  test "bootstrap cannot connect to nat node without a pre-existing connection":
    check await cannotConnect(bootstrap, natNode)

asyncchecksuite "NatTransport - Address-and-Port-Dependent Filtering":
  var bootstrap, thirdNode, natNode: Switch

  setup:
    let router = NatRouter.new(AddressAndPortDependent)
    bootstrap = newSwitch(Rng.instance())
    thirdNode = newSwitch(Rng.instance())
    natNode = newNatSwitch(router, Rng.instance())
    await bootstrap.start()
    await thirdNode.start()
    await natNode.start()

  teardown:
    await bootstrap.stop()
    await thirdNode.stop()
    await natNode.stop()

  test "bootstrap can connect to nat node with a pre-existing connection":
    await natNode.connect(bootstrap.peerInfo.peerId, bootstrap.peerInfo.addrs)
    check natNode.isConnected(bootstrap.peerInfo.peerId)

    await bootstrap.connect(natNode.peerInfo.peerId, natNode.peerInfo.addrs)
    check bootstrap.isConnected(natNode.peerInfo.peerId)

  test "bootstrap cannot connect to nat node without a pre-existing connection":
    check await cannotConnect(bootstrap, natNode)

  test "third node cannot connect to nat node even after nat node connected to bootstrap":
    await natNode.connect(bootstrap.peerInfo.peerId, bootstrap.peerInfo.addrs)
    check await cannotConnect(thirdNode, natNode)

asyncchecksuite "NatTransport - Double NAT":
  var bootstrap, natNode: Switch
  var router: NatRouter

  setup:
    router = NatRouter.new(DoubleNat)
    bootstrap = newSwitch(Rng.instance())
    natNode = newNatSwitch(router, Rng.instance())
    await bootstrap.start()
    await natNode.start()

  teardown:
    await bootstrap.stop()
    await natNode.stop()

  test "bootstrap cannot connect to nat node regardless of port mapping":
    let actualPort = initTAddress(natNode.peerInfo.addrs[0]).get().port
    let natMapper = NatPortMapper()
    natMapper.activeTcpPort = some(actualPort)
    router.natMapper = some(natMapper)

    check await cannotConnect(bootstrap, natNode)

asyncchecksuite "NatTransport - Port Mapping":
  var bootstrap, natNode: Switch
  var router: NatRouter

  setup:
    router = NatRouter.new(AddressAndPortDependent)
    bootstrap = newSwitch(Rng.instance())
    natNode = newNatSwitch(router, Rng.instance())
    await bootstrap.start()
    await natNode.start()

  teardown:
    await bootstrap.stop()
    await natNode.stop()

  test "bootstrap can connect to nat node when port mapping matches listen port":
    let actualPort = initTAddress(natNode.peerInfo.addrs[0]).get().port
    let natMapper = NatPortMapper()
    natMapper.activeTcpPort = some(actualPort)
    router.natMapper = some(natMapper)

    await bootstrap.connect(natNode.peerInfo.peerId, natNode.peerInfo.addrs)
    check bootstrap.isConnected(natNode.peerInfo.peerId)

  test "bootstrap cannot connect to nat node when port mapping does not match":
    let natMapper = NatPortMapper()
    natMapper.activeTcpPort = some(Port(1))
    router.natMapper = some(natMapper)

    check await cannotConnect(bootstrap, natNode)
