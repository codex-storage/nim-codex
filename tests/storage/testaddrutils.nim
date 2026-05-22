import std/[net, options]
import pkg/libp2p/multiaddress
import ../asynctest
import ../../storage/utils/addrutils

suite "addrutils - getTcpPort":
  test "extracts port from ipv4 tcp address":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    check getTcpPort(ma) == some(Port(5000))

  test "extracts port from ipv6 tcp address":
    let ma = MultiAddress.init("/ip6/::1/tcp/8080").expect("valid")
    check getTcpPort(ma) == some(Port(8080))

  test "returns none for udp address":
    let ma = MultiAddress.init("/ip4/1.2.3.4/udp/5000").expect("valid")
    check getTcpPort(ma) == Port.none

  test "extracts port 0":
    let ma = MultiAddress.init("/ip4/0.0.0.0/tcp/0").expect("valid")
    check getTcpPort(ma) == some(Port(0))

suite "addrutils - remapAddr":
  test "replaces protocol tcp with udp":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(protocol = some("udp"), port = some(Port(9000)))
    check remapped == MultiAddress.init("/ip4/1.2.3.4/udp/9000").expect("valid")

  test "replaces only port, keeping protocol":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(port = some(Port(9000)))
    check remapped == MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")

  test "replaces only ip, keeping protocol and port":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(ip = some(parseIpAddress("8.8.8.8")))
    check remapped == MultiAddress.init("/ip4/8.8.8.8/tcp/5000").expect("valid")
