import std/strformat

import pkg/unittest2

import pkg/libp2p/[multicodec, multihash]
import pkg/questionable/results
import pkg/stew/byteutils

import ../examples

import pkg/codex/bittorrent/magnetlink

suite "bittorrent magnet links":
  test "tt":
    let magnetLinkStr = "magnet:?xt=urn:btih:1902d602db8c350f4f6d809ed01eff32f030da95"
    let magnetLink = newMagnetLink(magnetLinkStr).tryGet()
    check $magnetLink == magnetLinkStr
  test "correctly parses magnet link version 1":
    let multiHash = MultiHash.example(Sha1HashCodec)
    let hash = multiHash.data.buffer[multiHash.dpos .. ^1]
    # echo byteutils.toHex(hash)
    # echo multiHash.hex
    let magnetLinkStr =
      fmt"magnet:?xt=urn:btih:{byteutils.toHex(hash).toUpperAscii}&dn=example.txt&tr=udp://tracker.example.com/announce&x.pe=31.205.250.200:8080"
    let magnetLink = newMagnetLink(magnetLinkStr).tryGet()
    check $magnetLink == magnetLinkStr.split("&")[0]

  test "correctly parses magnet link version 2":
    let multiHash = MultiHash.example()
    let magnetLinkStr =
      fmt"magnet:?xt=urn:btmh:{multihash.hex}&dn=example.txt&tr=udp://tracker.example.com/announce&x.pe=31.205.250.200:8080"
    let magnetLink = newMagnetLink(magnetLinkStr).tryGet()
    check $magnetLink == magnetLinkStr.split("&")[0]

  test "correctly parses hybrid magnet links":
    let multiHashV1 = MultiHash.example(Sha1HashCodec)
    let hash = multiHashV1.data.buffer[multiHashV1.dpos .. ^1]
    let multiHash = MultiHash.example()
    let magnetLinkStr =
      fmt"magnet:?xt=urn:btih:{byteutils.toHex(hash).toUpperAscii}&xt=urn:btmh:{multihash.hex}&dn=example.txt&tr=udp://tracker.example.com/announce&x.pe=31.205.250.200:8080"
    let magnetLink = newMagnetLink(magnetLinkStr).tryGet()
    check $magnetLink == magnetLinkStr.split("&")[0 .. 1].join("&")

  test "accepts hybrid magnet links with one info hash part incorrect (v1 part correct)":
    let multiHashV1 = MultiHash.example(Sha1HashCodec)
    let hash = multiHashV1.data.buffer[multiHashV1.dpos .. ^1]
    let magnetLinkStr =
      fmt"magnet:?xt=urn:btih:{byteutils.toHex(hash).toUpperAscii}&xt=urn:btmh&dn=example.txt&tr=udp://tracker.example.com/announce&x.pe=31.205.250.200:8080"
    let magnetLink = newMagnetLink(magnetLinkStr).tryGet()
    check $magnetLink == magnetLinkStr.split("&")[0]

  test "accepts hybrid magnet links with one info hash part incorrect (v2 part correct)":
    let multiHash = MultiHash.example()
    let magnetLinkStr =
      fmt"magnet:?xt=urn:btih&xt=urn:btmh:{multihash.hex}&dn=example.txt&tr=udp://tracker.example.com/announce&x.pe=31.205.250.200:8080"
    let magnetLink = newMagnetLink(magnetLinkStr).tryGet()
    check $magnetLink == "magnet:?" & magnetLinkStr.split("&")[1]

  test "fails for magnet links without 'magnet' prefix":
    let magnetLinkStr = "invalid_magnet_link"
    let magnetLink = newMagnetLink(magnetLinkStr)
    check magnetLink.isFailure
    check magnetLink.error.msg ==
      "Invalid magnet link format (missing 'magnet:?' prefix)"

  test "fails for magnet links without 'infoHash' part":
    let magnetLinkStr =
      "magnet:?dn=example.txt&tr=udp://tracker.example.com/announce&x.pe=31.205.250.200:8080"
    let magnetLink = newMagnetLink(magnetLinkStr)
    check magnetLink.isFailure
    check magnetLink.error.msg ==
      "Invalid magnet link format (at least one info hash part is required)"

  for (magnetLinkStr, errorMsg) in [
    (
      "magnet:?xt=urn:btih:",
      "Error parsing info hash: given bytes is not a correct multihash",
    ),
    (
      "magnet:?xt=urn:btmh:",
      "Error parsing info hash: given bytes is not a correct multihash",
    ),
    (
      "magnet:?xt=urn:btih:1234567890&xt=urn:btmh:",
      "Error parsing info hash: given bytes is not a correct multihash",
    ),
    (
      "magnet:?xt=urn:btih:1234567890&xt=urn:btmh:1234567890",
      "Error parsing info hash: given bytes is not a correct multihash",
    ),
    (
      "magnet:?xt=urn:btmh:1234567890&xt=urn:btih:",
      "Error parsing info hash: given bytes is not a correct multihash",
    ),
    (
      "magnet:?xt=urn:btmh:1234567890&xt=urn:btih:1234567890",
      "Error parsing info hash: given bytes is not a correct multihash",
    ),
    (
      "magnet:?xt=urn:btmh:&xt=urn:btih:1234567890",
      "Error parsing info hash: given bytes is not a correct multihash",
    ),
    (
      "magnet:?xt=urn:btih:&xt=urn:btmh:1234567890",
      "Error parsing info hash: given bytes is not a correct multihash",
    ),
    ("magnet:?xt=urn:btih", "Invalid magnet link format (missing info hash part)"),
    ("magnet:?xt=urn:btmh", "Invalid magnet link format (missing info hash part)"),
  ]:
    test fmt"fails for magnet links with invalid hashes: {magnetLinkStr}":
      let magnetLink = newMagnetLink(magnetLinkStr)
      check magnetLink.isFailure
      check magnetLink.error.msg == errorMsg
