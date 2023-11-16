import std/math
import std/options
import std/strformat
import std/strutils
import std/unittest
import pkg/chronicles except toJson
import pkg/stew/byteutils
import pkg/stint
import pkg/codex/contracts/requests
from pkg/codex/rest/json import RestPurchase
import pkg/codex/utils/json as utilsjson
import pkg/questionable
import pkg/questionable/results
import ../helpers

checksuite "json serialization":
  var request: StorageRequest
  var requestJson: JsonNode

  func flatten(s: string): string =
    s.replace(" ")
     .replace("\n")

  setup:
    request = StorageRequest(
      client: Address.init("0xebcb2b4c2e3c9105b1a53cd128c5ed17c3195174").get(),
      ask: StorageAsk(
        slots: 4,
        slotSize: (1 * 1024 * 1024 * 1024).u256, # 1 Gigabyte
        duration: (10 * 60 * 60).u256, # 10 hours
        collateral: 200.u256,
        proofProbability: 4.u256, # require a proof roughly once every 4 periods
        reward: 84.u256,
        maxSlotLoss: 2 # 2 slots can be freed without data considered to be lost
      ),
      content: StorageContent(
        cid: "zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob",
        merkleRoot: array[32, byte].fromHex("0xc066dd7e405de5a795ce1e765209cfaa6de6c74829c607d1a2fe53107107a298")
      ),
      expiry: 1691545330.u256,
      nonce: Nonce array[32, byte].fromHex("0xd4ebeadc44641c0a271153f6366f24ebb5e3aa64f9ee5e62794babc2e75950a1")
    )
    requestJson = """{
                      "client": "0xebcb2b4c2e3c9105b1a53cd128c5ed17c3195174",
                      "ask": {
                        "slots": 4,
                        "slotSize": "1073741824",
                        "duration": "36000",
                        "proofProbability": "4",
                        "reward": "84",
                        "collateral": "200",
                        "maxSlotLoss": 2
                      },
                      "content": {
                        "cid": "zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob",
                        "merkleRoot": "0xc066dd7e405de5a795ce1e765209cfaa6de6c74829c607d1a2fe53107107a298"
                      },
                      "expiry": "1691545330",
                      "nonce": "0xd4ebeadc44641c0a271153f6366f24ebb5e3aa64f9ee5e62794babc2e75950a1"
                    }""".parseJson

  test "serializes UInt256 to non-hex string representation":
    check (% 100000.u256) == newJString("100000")

  test "serializes sequence to an array":
    let json = % @[1, 2, 3]
    let expected = "[1,2,3]"
    check $json == expected

  test "serializes Option[T] when has a value":
    let obj = %(some 1)
    let expected = "1"
    check $obj == expected

  test "serializes Option[T] when doesn't have a value":
    let obj = %(none int)
    let expected = "null"
    check $obj == expected

  test "serializes uints int.high or smaller":
    let largeUInt: uint = uint(int.high)
    check %largeUInt == newJInt(BiggestInt(largeUInt))

  test "serializes large uints":
    let largeUInt: uint = uint(int.high) + 1'u
    check %largeUInt == newJString($largeUInt)


  test "serializes Inf float":
    check %Inf == newJString("inf")

  test "serializes -Inf float":
    check %(-Inf) == newJString("-inf")

  test "deserializes NaN float":
    check %NaN == newJString("nan")

  test "can construct json objects with %*":
    type MyObj = object
      mystring {.serialize.}: string
      myint {.serialize.}: int
      myoption {.serialize.}: ?bool

    let myobj = MyObj(mystring: "abc", myint: 123, myoption: some true)
    let mystuint = 100000.u256

    let json = %*{
      "myobj": myobj,
      "mystuint": mystuint
    }

    let expected = """{
                        "myobj": {
                          "mystring": "abc",
                          "myint": 123,
                          "myoption": true
                        },
                        "mystuint": "100000"
                      }""".flatten

    check $json == expected

  test "only serializes marked fields":
    type MyObj = object
      mystring {.serialize.}: string
      myint {.serialize.}: int
      mybool: bool

    let obj = % MyObj(mystring: "abc", myint: 1, mybool: true)

    let expected = """{
                        "mystring": "abc",
                        "myint": 1
                      }""".flatten

    check $obj == expected

  test "serializes ref objects":
    type MyRef = ref object
      mystring {.serialize.}: string
      myint {.serialize.}: int

    let obj = % MyRef(mystring: "abc", myint: 1)

    let expected = """{
                        "mystring": "abc",
                        "myint": 1
                      }""".flatten

    check $obj == expected

  test "serializes RestPurchase":
    let request = % RestPurchase(
      request: some request,
      requestId: RequestId.fromHex("0xd4ebeadc44641c0a271153f6366f24ebb5e3aa64f9ee5e62794babc2e75950a1"),
      error: some "error",
      state: "state"
    )
    let expected = """{
                        "requestId": "0xd4ebeadc44641c0a271153f6366f24ebb5e3aa64f9ee5e62794babc2e75950a1",
                        "request": {
                          "client": "0xebcb2b4c2e3c9105b1a53cd128c5ed17c3195174",
                          "ask": {
                            "slots": 4,
                            "slotSize": "1073741824",
                            "duration": "36000",
                            "proofProbability": "4",
                            "reward": "84",
                            "collateral": "200",
                            "maxSlotLoss": 2
                          },
                          "content": {
                            "cid": "zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob"
                          },
                          "expiry": "1691545330"
                        },
                        "state": "state",
                        "error": "error"
                      }""".flatten
    check $request == expected

  test "serializes StorageRequest":
    let expected = """{
                        "client": "0xebcb2b4c2e3c9105b1a53cd128c5ed17c3195174",
                        "ask": {
                          "slots": 4,
                          "slotSize": "1073741824",
                          "duration": "36000",
                          "proofProbability": "4",
                          "reward": "84",
                          "collateral": "200",
                          "maxSlotLoss": 2
                        },
                        "content": {
                          "cid": "zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob"
                        },
                        "expiry": "1691545330"
                      }""".flatten
    check request.toJson == expected

  test "deserialize enum":
    let json = newJString($CidVersion.CIDv1)
    check !CidVersion.fromJson(json) == CIDv1

  test "deserializes UInt256 from non-hex string representation":
    let json = newJString("100000")
    check !UInt256.fromJson(json) == 100000.u256

  test "deserializes Option[T] when has a value":
    let json = newJInt(1)
    check (!fromJson(?int, json) == some 1)

  test "deserializes Option[T] when doesn't have a value":
    let json = newJNull()
    check !fromJson(?int, json) == none int

  test "deserializes float":
    let json = newJFloat(1.234)
    check !float.fromJson(json) == 1.234

  test "deserializes Inf float":
    let json = newJString("inf")
    check !float.fromJson(json) == Inf

  test "deserializes -Inf float":
    let json = newJString("-inf")
    check !float.fromJson(json) == -Inf

  test "deserializes NaN float":
    let json = newJString("nan")
    check float.fromJson(json).get.isNaN

  test "deserializes array to sequence":
    let expected = @[1, 2, 3]
    let json = "[1,2,3]".parseJson
    check !seq[int].fromJson(json) == expected

  test "deserializes uints int.high or smaller":
    let largeUInt: uint = uint(int.high)
    let json = newJInt(BiggestInt(largeUInt))
    check !uint.fromJson(json) == largeUInt

  test "deserializes large uints":
    let largeUInt: uint = uint(int.high) + 1'u
    let json = newJString($BiggestUInt(largeUInt))
    check !uint.fromJson(json) == largeUInt

  test "can deserialize json objects":
    type MyObj = object
      mystring: string
      myint: int
      myoption: ?bool

    let expected = MyObj(mystring: "abc", myint: 123, myoption: some true)

    let json = parseJson("""{
                              "mystring": "abc",
                              "myint": 123,
                              "myoption": true
                            }""")
    check !MyObj.fromJson(json) == expected

  test "ignores serialize pragma when deserializing":
    type MyObj = object
      mystring {.serialize.}: string
      mybool: bool

    let expected = MyObj(mystring: "abc", mybool: true)

    let json = parseJson("""{
                              "mystring": "abc",
                              "mybool": true
                            }""")

    check !MyObj.fromJson(json) == expected

  test "deserializes objects with extra fields":
    type MyObj = object
      mystring: string
      mybool: bool

    let expected = MyObj(mystring: "abc", mybool: true)

    let json = """{
                    "mystring": "abc",
                    "mybool": true,
                    "extra": "extra"
                  }""".parseJson
    check !MyObj.fromJson(json) == expected

  test "deserializes objects with less fields":
    type MyObj = object
      mystring: string
      mybool: bool

    let expected = MyObj(mystring: "abc", mybool: false)

    let json = """{
                    "mystring": "abc"
                  }""".parseJson
    check !MyObj.fromJson(json) == expected

  test "deserializes ref objects":
    type MyRef = ref object
      mystring: string
      myint: int

    let expected = MyRef(mystring: "abc", myint: 1)

    let json = """{
                    "mystring": "abc",
                    "myint": 1
                  }""".parseJson

    let deserialized = !MyRef.fromJson(json)
    check deserialized.mystring == expected.mystring
    check deserialized.myint == expected.myint

  test "deserializes Cid":
    let
      jCid = newJString("zdj7Wakya26ggQWkvMdHYFcPgZ7Qh2HdMooQDDFDHkk4uHS14")
      cid = "zdj7Wakya26ggQWkvMdHYFcPgZ7Qh2HdMooQDDFDHkk4uHS14"

    check:
      !Cid.fromJson(jCid) == !Cid.init(cid).mapFailure

  test "deserializes StorageRequest":
    check !StorageRequest.fromJson(requestJson) == request

  test "deserializes RestPurchase":
    let json = """{
                    "requestId": "0xd4ebeadc44641c0a271153f6366f24ebb5e3aa64f9ee5e62794babc2e75950a1",
                    "state": "state",
                    "error": "error"
                  }""".parseJson
    json["request"] = requestJson

    let expected = RestPurchase(
      requestId: RequestId.fromHex("0xd4ebeadc44641c0a271153f6366f24ebb5e3aa64f9ee5e62794babc2e75950a1"),
      state: "state",
      error: some "error",
      request: some request
    )
    check !RestPurchase.fromJson(json) == expected
