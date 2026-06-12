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
    disc = Discovery.new(key, announceAddrs = @[])

  test "announceDirectAddrs sets the SPR with both TCP and UDP addresses":
    disc.announceDirectAddrs(@[directAddr], udpPort)

    let spr = disc.getSpr()
    let addrs = spr.data.addresses.mapIt($it.address)
    check addrs.anyIt(it.contains("/tcp/"))
    check addrs.anyIt(it.contains("/udp/"))

  test "announceRelayAddrs updates the SPR with the announce addresses":
    disc.announceDirectAddrs(@[directAddr], udpPort)

    disc.announceRelayAddrs(@[relayAddr])

    let addrs = disc.getSpr().data.addresses.mapIt($it.address)
    check addrs == @[$relayAddr]
