import std/[unittest, net, options]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/results

import ../../storage/nat {.all.}
import ../../storage/utils
import ../../storage/utils/natutils

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

suite "NAT restart safety":
  test "setupNat does not crash when extIp is cached from a previous start":
    # Reproduces the restart crash (SIGSEGV) seen with nat=upnp.
    #
    # After a first start, extIp was cached and upnp was initialised.
    # After a stop, extIp was still cached, but upnp was not initialised because
    # the thread was destroyed using the destroy function.
    # As a result, the next start crashed in setupNat when it tried to do port mapping
    # because getExternalIp wasn't called anymore (it was cached) and upnp was not initialised.
    extIp = some(parseIpAddress("1.2.3.4"))
    strategy = NatStrategy.NatUpnp

    let res = setupNat(NatStrategy.NatUpnp, Port(8500), Port(8500), "storage")
    check res.tcpPort.isSome

  test "stopNat resets NAT state so the next start is clean":
    # Simulates leftover state
    extIp = some(parseIpAddress("1.2.3.4"))
    strategy = NatStrategy.NatNone
    activeMappings.add(PortMappings())

    stopNat()

    check extIp.isNone
    check activeMappings.len == 0
    check natThreads.len == 0
