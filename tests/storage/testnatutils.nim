import std/[unittest, net, options]
import pkg/chronos
import ../../storage/utils/natutils

suite "isGlobalUnicast":
  test "localhost IPv4 is not global unicast":
    check not isGlobalUnicast(parseIpAddress("127.0.0.1"))

  test "unspecified IPv4 is not global unicast":
    check not isGlobalUnicast(parseIpAddress("0.0.0.0"))

  test "link-local IPv4 is not global unicast":
    check not isGlobalUnicast(parseIpAddress("169.254.1.1"))

  test "private IPv4 is not global unicast":
    check not isGlobalUnicast(parseIpAddress("10.0.0.1"))

  test "public IPv4 is global unicast":
    check isGlobalUnicast(parseIpAddress("8.8.8.8"))

  test "localhost IPv6 is not global unicast":
    check not isGlobalUnicast(parseIpAddress("::1"))

  test "unspecified IPv6 is not global unicast":
    check not isGlobalUnicast(parseIpAddress("::"))

  test "link-local IPv6 is not global unicast":
    check not isGlobalUnicast(parseIpAddress("fe80::1"))

  test "private IPv6 is not global unicast":
    check not isGlobalUnicast(parseIpAddress("fc00::1"))

  test "public IPv6 is global unicast":
    check isGlobalUnicast(parseIpAddress("2606:4700::1"))

suite "getRoute":
  test "getRouteIpv4 returns a valid IPv4":
    let res = getRouteIpv4()

    check res.isOk
    check res.get().family == IpAddressFamily.IPv4

  test "getRouteIpv6 returns a valid IPv6":
    let res = getRouteIpv6()
    # If the machine does not have a global route because
    # it is not configured for IPv6, the test will fail
    # because it didn't find the best route. In that case,
    # we can just skip the test, because it is not a problem
    # with the test itself but the machine configuration.
    if res.isErr:
      check res.error == "No best route found"
    else:
      check res.get().family == IpAddressFamily.IPv6

suite "getBestLocalAddress":
  test "specific IPv4 is returned as it is":
    let ip = parseIpAddress("192.168.1.1")
    check getBestLocalAddress(ip) == some(ip)

  test "specific IPv6 is returned as it is":
    let ip = parseIpAddress("2606:4700::1")
    check getBestLocalAddress(ip) == some(ip)

  test "0.0.0.0 resolves to a local IPv4":
    let res = getBestLocalAddress(parseIpAddress("0.0.0.0"))
    check res.isSome
    check res.get().family == IpAddressFamily.IPv4
