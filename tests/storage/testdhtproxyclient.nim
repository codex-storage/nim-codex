import std/strutils
import pkg/libp2p/[multiaddress, routing_record]
import pkg/libp2p_mix

import ../asynctest
import ./helpers
import ./examples
import ../../storage/rng
import ../../storage/dht_proxy/client
import ../../storage/utils/mixidentity

asyncchecksuite "DHT proxy - lookupProviders":
  var mixProto: MixProtocol
  var cid: Cid

  let
    tcpAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    udpAddr = MultiAddress.init("/ip4/1.2.3.4/udp/4001").expect("valid")

  setup:
    cid = Cid.example

    var nodeInfo = MixNodeInfo.generateRandom(0, Rng.instance().libp2pRng)
    nodeInfo.multiAddr = mixUnsetMultiAddr()
    mixProto = MixProtocol.new(nodeInfo, newStandardSwitch())

  test "fails when the proxy advertises no address":
    let proxy = PeerRecord.init(PeerId.example, newSeq[MultiAddress]())

    let res = await lookupProviders(mixProto, proxy, cid)

    check res.isFailure
    check "Proxy has no addresses" in res.error.msg

  test "fails when no proxy address is Mix-compatible":
    let proxy = PeerRecord.init(PeerId.example, @[udpAddr])

    let res = await lookupProviders(mixProto, proxy, cid)

    check res.isFailure
    check "No Mix-compatible address" in res.error.msg

  test "fails when the local Mix address is not updated yet":
    let proxy = PeerRecord.init(PeerId.example, @[tcpAddr])

    let res = await lookupProviders(mixProto, proxy, cid)

    check res.isFailure
    check "MixProtocol is not ready" in res.error.msg

  test "the lookup starts when the local Mix address is updated":
    mixProto.setLocalMultiAddr(tcpAddr).expect("Mix-encodable address")
    let proxy = PeerRecord.init(PeerId.example, @[tcpAddr])

    let res = await lookupProviders(mixProto, proxy, cid)

    # We expect a failure because we don't have a proper Mix setup.
    # If we get "no destination read behavior", it means we that mixProto.toConnection
    # was called so the Mix address was ready to be used.
    check res.isFailure
    check "no destination read behavior" in res.error.msg
