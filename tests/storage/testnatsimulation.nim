import pkg/chronos

import ./helpers
import ../asynctest
import ../../storage/rng
import ../../storage/utils/natsimulation

const flags = {ServerFlags.ReuseAddr}
const listenAddr = "/ip4/127.0.0.1/tcp/0"

proc newSwitch(rng: Rng): Switch =
  SwitchBuilder
    .new()
    .withRng(rng)
    .withPrivateKey(PrivateKey.random(rng[]).get())
    .withAddresses(@[MultiAddress.init(listenAddr).get()])
    .withTcpTransport(flags)
    .withNoise()
    .withYamux()
    .build()

proc newNatSwitch(router: NatRouter, rng: Rng): Switch =
  SwitchBuilder
    .new()
    .withRng(rng)
    .withPrivateKey(PrivateKey.random(rng[]).get())
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
    expect(LPError):
      await bootstrap.connect(natNode.peerInfo.peerId, natNode.peerInfo.addrs)

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
    expect(LPError):
      await bootstrap.connect(natNode.peerInfo.peerId, natNode.peerInfo.addrs)

  test "third node cannot connect to nat node even after nat node connected to bootstrap":
    await natNode.connect(bootstrap.peerInfo.peerId, bootstrap.peerInfo.addrs)
    expect(LPError):
      await thirdNode.connect(natNode.peerInfo.peerId, natNode.peerInfo.addrs)
