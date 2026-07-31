import std/[net, sequtils]
import pkg/libp2p/[multiaddress, routing_record]
import pkg/libp2p_mix

import ../asynctest
import ./helpers
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils/mixidentity

suite "Discovery - SPR record logic":
  var key: PrivateKey
  var disc: Discovery

  let
    directAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    relayAddr = MultiAddress
      .init(
        "/ip4/5.6.7.8/tcp/4002/p2p/16Uiu2HAmQu456Ae52JqPuqog6wCex47LLvNY8oHMBC4GRRtaStHs/p2p-circuit"
      )
      .expect("valid")
    udpPort = Port(8090)

  setup:
    key = PrivateKey.random(Rng.instance().libp2pRng).get()
    disc = Discovery.new(key, providerAddrs = @[])

  test "SPR contains provider (TCP) and discovery addresses (UDP) after announceDirectAddrs":
    disc.announceDirectAddrs(@[directAddr], udpPort)

    let addrs = disc.getSpr().data.addresses.mapIt($it.address)
    check addrs.anyIt(it.contains("/tcp/"))
    check addrs.anyIt(it.contains("/udp/"))

  test "announceDirectAddrs updates the provider record with TCP addresses only":
    disc.announceDirectAddrs(@[directAddr], udpPort)

    let providerAddrs = disc.providerRecord.get.data.addresses.mapIt($it.address)
    check providerAddrs.anyIt(it.contains("/tcp/"))
    check not providerAddrs.anyIt(it.contains("/udp/"))

  test "announceDirectAddrs updates the local record with UDP addresses only":
    disc.announceDirectAddrs(@[directAddr], udpPort)

    let discoveryAddrs = disc.protocol.getRecord().data.addresses.mapIt($it.address)
    check discoveryAddrs.anyIt(it.contains("/udp/"))
    check not discoveryAddrs.anyIt(it.contains("/tcp/"))

  test "SPR contains provider (TCP) after announceRelayAddrs":
    disc.announceRelayAddrs(@[relayAddr])

    let addrs = disc.getSpr().data.addresses.mapIt($it.address)
    check addrs.anyIt(it.contains("/tcp/"))
    check not addrs.anyIt(it.contains("/udp/"))

  test "announceRelayAddrs updates the provider record with TCP addresses only":
    disc.announceRelayAddrs(@[relayAddr])

    let providerAddrs = disc.providerRecord.get.data.addresses.mapIt($it.address)
    check providerAddrs.anyIt(it.contains("/tcp/"))
    check not providerAddrs.anyIt(it.contains("/udp/"))

  test "announceRelayAddrs does not update the local record":
    disc.announceRelayAddrs(@[relayAddr])

    let discoveryAddrs = disc.protocol.getRecord().data.addresses.mapIt($it.address)
    check discoveryAddrs.len == 0

suite "Discovery - Mix local address":
  var key: PrivateKey
  var disc: Discovery
  var mixProto: MixProtocol

  let
    directAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    otherAddr = MultiAddress.init("/ip4/9.9.9.9/tcp/4003").expect("valid")
    udpAddr = MultiAddress.init("/ip4/1.2.3.4/udp/4001").expect("valid")
    ip6Addr = MultiAddress.init("/ip6/::1/tcp/4001").expect("valid")
    circuitAddr = MultiAddress
      .init(
        "/ip4/5.6.7.8/tcp/4002/p2p/16Uiu2HAmQu456Ae52JqPuqog6wCex47LLvNY8oHMBC4GRRtaStHs/p2p-circuit"
      )
      .expect("valid")
    udpPort = Port(8090)

  setup:
    key = PrivateKey.random(Rng.instance().libp2pRng).get()
    disc = Discovery.new(key, providerAddrs = @[])

    # Mirror the node startup: no dialable address known yet.
    var nodeInfo = MixNodeInfo.generateRandom(0, Rng.instance().libp2pRng)
    nodeInfo.multiAddr = mixUnsetMultiAddr()
    mixProto = MixProtocol.new(nodeInfo, newStandardSwitch())
    disc.mixProto = mixProto

  test "announceDirectAddrs sets the Mix local address":
    disc.announceDirectAddrs(@[directAddr], udpPort)

    check $mixProto.localMixPubInfo.multiAddr == $directAddr

  test "announceRelayAddrs sets the Mix local address":
    disc.announceRelayAddrs(@[circuitAddr])

    check $mixProto.localMixPubInfo.multiAddr == $circuitAddr

  test "a new announce replaces the Mix local address":
    disc.announceDirectAddrs(@[directAddr], udpPort)
    disc.announceDirectAddrs(@[otherAddr], udpPort)

    check $mixProto.localMixPubInfo.multiAddr == $otherAddr

  test "clearing the announce resets the Mix local address":
    disc.announceDirectAddrs(@[directAddr], udpPort)
    disc.announceDirectAddrs(@[], udpPort)

    check $mixProto.localMixPubInfo.multiAddr == $mixUnsetMultiAddr()

  test "an announce with no Mix-compatible address resets the Mix local address":
    disc.announceDirectAddrs(@[directAddr], udpPort)
    disc.announceDirectAddrs(@[udpAddr], udpPort)

    check $mixProto.localMixPubInfo.multiAddr == $mixUnsetMultiAddr()
