import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors
import pkg/protobuf_serialization

import pkg/codex/rng
import pkg/codex/chunker
import pkg/codex/storageproofs
import pkg/codex/discovery
import pkg/codex/hostaddress

import ../examples
import ../helpers

suite "StorageProofs Network":
  let
    rng = Rng.instance()
    seckey1 = PrivateKey.random(rng[]).tryGet()
    seckey2 = PrivateKey.random(rng[]).tryGet()
    hostAddr1 = HostAddress(array[20, byte].example)
    hostAddr2 = HostAddress(array[20, byte].example)

  var
    stpNetwork1: StpNetwork
    stpNetwork2: StpNetwork
    switch1: Switch
    switch2: Switch
    discovery1: Discovery
    discovery2: Discovery

  setup:
    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()

    discovery1 = Discovery.new(switch1.peerInfo)
    discovery2 = Discovery.new(switch2.peerInfo)

    stpNetwork1 = StpNetwork.new(switch1, discovery1)
    stpNetwork2 = StpNetwork.new(switch2, discovery2)

    switch1.mount(stpNetwork1)
    switch2.mount(stpNetwork2)

    await switch1.start()
    await switch2.start()

    await discovery1.start()
    await discovery2.start()

  teardown:
    await switch1.stop()
    await switch2.stop()

    await discovery1.stop()
    await discovery2.stop()

  test "Should upload to host":
    let
      conn = await switch1.dial(
        switch2.peerInfo.peerId,
        switch2.peerInfo.addrs,
        storageproofs.Codec)
