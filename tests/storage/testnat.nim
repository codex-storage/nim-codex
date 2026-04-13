import std/[unittest, net]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/results

import ../../storage/nat
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

suite "setupAddress":
  test "public bind IP with NatNone returns bind IP":
    let
      bindIp = parseIpAddress("8.8.8.8")
      natConfig = NatConfig(hasExtIp: false, nat: NatStrategy.NatNone)
      (ip, tcpPort, udpPort) =
        setupAddress(natConfig, bindIp, Port(5000), Port(5001), "test")

    check ip == some(bindIp)
    check tcpPort == some(Port(5000))
    check udpPort == some(Port(5001))

  test "private bind IP with NatNone returns no IP":
    let
      bindIp = parseIpAddress("192.168.1.1")
      natConfig = NatConfig(hasExtIp: false, nat: NatStrategy.NatNone)
      (ip, tcpPort, udpPort) =
        setupAddress(natConfig, bindIp, Port(5000), Port(5001), "test")

    check ip == none(IpAddress)
    check tcpPort == some(Port(5000))
    check udpPort == some(Port(5001))
