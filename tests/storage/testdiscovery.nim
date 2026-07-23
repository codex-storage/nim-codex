import std/[net, sequtils]
import pkg/libp2p/[multiaddress, routing_record]

import ../asynctest
import ./helpers
import ../../storage/discovery
import ../../storage/rng

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

  test "announceDirectAddrs update the provider record with TCP addresses only":
    disc.announceDirectAddrs(@[directAddr], udpPort)

    let providerAddrs = disc.providerRecord.get.data.addresses.mapIt($it.address)
    check providerAddrs.anyIt(it.contains("/tcp/"))
    check not providerAddrs.anyIt(it.contains("/udp/"))

  test "announceDirectAddrs update the local record with UDP addresses only":
    disc.announceDirectAddrs(@[directAddr], udpPort)

    let discoveryAddrs = disc.protocol.getRecord().data.addresses.mapIt($it.address)
    check discoveryAddrs.anyIt(it.contains("/udp/"))
    check not discoveryAddrs.anyIt(it.contains("/tcp/"))

  test "SPR contains provider (TCP) after announceRelayAddrs":
    disc.announceRelayAddrs(@[directAddr])

    let addrs = disc.getSpr().data.addresses.mapIt($it.address)
    check addrs.anyIt(it.contains("/tcp/"))
    check not addrs.anyIt(it.contains("/udp/"))

  test "announceRelayAddrs update the provider record with TCP addresses only":
    disc.announceRelayAddrs(@[directAddr])

    let providerAddrs = disc.providerRecord.get.data.addresses.mapIt($it.address)
    check providerAddrs.anyIt(it.contains("/tcp/"))
    check not providerAddrs.anyIt(it.contains("/udp/"))

  test "announceRelayAddrs does not update the local record":
    disc.announceRelayAddrs(@[directAddr])

    let discoveryAddrs = disc.protocol.getRecord().data.addresses.mapIt($it.address)
    check discoveryAddrs.len == 0
