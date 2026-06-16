import std/tables

import pkg/unittest2
import pkg/libp2p/peerid
import pkg/storage/utils/mixidentity {.all.}

const SamplePoolJson = """
{
  "version": 1,
  "relays": [
    {
      "peerId": "16Uiu2HAmNNzXL3wnW64pPFJDwrSJnNaX4CNLeWPbzdPcVJhRTGwP",
      "multiAddr": "/ip4/127.0.0.1/tcp/4242",
      "mixPubKey": "8a6571e8665fb1c894215f97d6a244591b655b1f5fd5ff7f928ef8b74aa66c5f",
      "libp2pPubKey": "03907bc5a41bec7c5ba11f8dfe6c7f779328d2d5bb48c9a978a11e09f3fbf61b3e"
    },
    {
      "peerId": "16Uiu2HAmM6CDJa9HJQ76cRubcpAmrHfMcUCvYncA9M4BfFFEszQn",
      "multiAddr": "/ip4/127.0.0.1/tcp/4243",
      "mixPubKey": "f268d04a1a0903ecf63a3441b986eae414579aa47ff22b071370e6fcd9d3b45c",
      "libp2pPubKey": "037d526dab2572c2336f721813964011899ba7d11a3ebebed1d22d1dea2b74e547"
    }
  ]
}
"""

suite "mixidentity / loadRelayPubInfoTableFromJson":
  test "empty string yields an empty table":
    let res = loadRelayPubInfoTableFromJson("")
    check res.isOk
    check res.get.len == 0

  test "parses a well-formed pool":
    let res = loadRelayPubInfoTableFromJson(SamplePoolJson)
    check res.isOk
    let t = res.get
    check t.len == 2
    let
      p0 = PeerId.init("16Uiu2HAmNNzXL3wnW64pPFJDwrSJnNaX4CNLeWPbzdPcVJhRTGwP").get
      p1 = PeerId.init("16Uiu2HAmM6CDJa9HJQ76cRubcpAmrHfMcUCvYncA9M4BfFFEszQn").get
    check p0 in t
    check p1 in t

  test "rejects malformed JSON":
    let res = loadRelayPubInfoTableFromJson("{not json")
    check res.isErr

  test "rejects unsupported version":
    let
      json = """{"version": 99, "relays": []}"""
      res = loadRelayPubInfoTableFromJson(json)
    check res.isErr

  test "rejects missing relays array":
    let
      json = """{"version": 1}"""
      res = loadRelayPubInfoTableFromJson(json)
    check res.isErr

  test "rejects entry missing required field":
    let json = """
{
  "version": 1,
  "relays": [
    {
      "peerId": "16Uiu2HAmNNzXL3wnW64pPFJDwrSJnNaX4CNLeWPbzdPcVJhRTGwP",
      "multiAddr": "/ip4/127.0.0.1/tcp/4242",
      "mixPubKey": "8a6571e8665fb1c894215f97d6a244591b655b1f5fd5ff7f928ef8b74aa66c5f"
    }
  ]
}
"""
    let res = loadRelayPubInfoTableFromJson(json)
    check res.isErr
