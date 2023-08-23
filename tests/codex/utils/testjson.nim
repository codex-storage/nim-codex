import std/math
import std/options
import std/strformat
import std/strutils
import std/unittest
import pkg/chronicles
import pkg/stew/byteutils
import pkg/stint
import pkg/codex/contracts/requests
from pkg/codex/rest/json import RestPurchase
import pkg/codex/utils/json as utilsjson
import pkg/questionable
import pkg/questionable/results
import ../examples
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
        erasure: StorageErasure(
          totalChunks: 12,
        ),
        por: StoragePoR(
          u: @(array[480, byte].fromHex("0xc066dd7e405de5a795ce1e765209cfaa6de6c74829c607d1a2fe53107107a2981baccff95e2fc2e38d08303e8ab59a1169cfc9bfbfa2294c6df065456056a0d0106f66d6fe48300222758fd6fd286a1ac9060d1a295e19f931a8d3ad2c47eb131bea267fe942d460fda96fd4bf663148cd90fbb1b670dd97aae70394248b75cfbb98f71e8c69f50381e0558884d5d9aa75147923b55386c66f75f63024b698eeb0ff994bfdb610eea1b7c75e87bdb54843071bc64fbaf93e5dc214e875bd95bd30f167b69df1de819a34cc71a3a0465f5c1d1b7e5b98de6017ff3e3c059536f974471fe62e0f224eba8f96352a8ee51befbf4c31c88ad0fc8ff4e9d9da174a455a1c30fd61ac977145d3677a08167d508fae207f9458a9b19d4ceec2be30506e2d70cc0362c2bcdb0f73d63fa5e79f9b2901bc870ac8b2a264d50e1862ea177eb587bcd16ceb7d66f96f198cadec3f644af4d3cbe478bc1665818401f89107053d1750047fb7cfc47938bec2cd006db9c176ce337e41160077e353f87ab319e5b9df92282916ef99334c067f6ca20c3d7cbc12b95180b7bba762993a4dbdf4242032da8865988183738d279918906c3357701d74e5d8f5142315ae8f6d0f93537abc3545118e953f983317657a9d8b86e4305ea49e10f80ea07dc7ea7321b32c")),
          publicKey: @(array[96, byte].fromHex("0xb231b19de641f678d250623b2b76099ab4bbd67aac19dcf42ded946831e3366d2a20af0fd9e841197e7e64d7639da4518b76c353db480087e21d55b470f24a180d6d6c8265bf3895e2e4e4e54b8ca9334d62b22feeeed8e77e54bfbc8fae6b62")),
          name: @(array[512, byte].fromHex("0x75b2ac401efd21e60e84a69288da6fff28c7badaae885e417f35055a4e10cb514855f68a0ae18bf42861426c9fc34af13df2f2d04dc68933af78bf3fc396953f301b95f6d6af54ec9fc871c292096e45b91e836063f128c2d1469adbee49bc9b7d62985a858801e4df2cb77eb41ee7b50a8a4e5afb5b585f9034a2808f81bd95b9a3fbdd2579331023f1816a1ecbe7a31e386721a72e3d0ff6087326fba8442dfd22d1182c85906d796e697231c2d7d4a888ae256c79a9019974a4c729d981f3e554f48895e27fe8f45da46bc48c35cc74ae5a31dfea8baa1334fa7f106cdc4ec54452f39c823fa0af97769217cc16c78eb7d0c494c26d2f286f09a507bd04cb15963270bffefb28258176d9e10b7aaad76cdd86e0fe49437eb83c1c0650cb5920e32dc54f3a21a70308b7312b47ce57ef72c2c19eba5027612128b747e80b88c912d7fc10177e67beda0ed5bb8fdfc268bfa5a5c700da953c56bcc79b9186da99ee19a6fa954f44bdcbc7c7f4d208fb750bad587d5513fbaccd511b9b6e0cd798120de87b9c0c410b3b85c75a8a0f469d9973a1ec4c86982cf4fe1a2be21a9206aaabb1ad2fafa628d5156d2ec99ee30fc0ddb9dca6a4cd3a7987227315ceeaa832909853cabaf33c976b59cf5ed9643781d92ab769c0d0aa3bcef40b41b4b3e6fc5a00c9dfbf794047d9cfb97d9d669d00520b6492760a08dba65b0fd7e6d0"))
        )
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
                        "erasure": {
                          "totalChunks": 12
                        },
                        "por": {
                          "u": "0xc066dd7e405de5a795ce1e765209cfaa6de6c74829c607d1a2fe53107107a2981baccff95e2fc2e38d08303e8ab59a1169cfc9bfbfa2294c6df065456056a0d0106f66d6fe48300222758fd6fd286a1ac9060d1a295e19f931a8d3ad2c47eb131bea267fe942d460fda96fd4bf663148cd90fbb1b670dd97aae70394248b75cfbb98f71e8c69f50381e0558884d5d9aa75147923b55386c66f75f63024b698eeb0ff994bfdb610eea1b7c75e87bdb54843071bc64fbaf93e5dc214e875bd95bd30f167b69df1de819a34cc71a3a0465f5c1d1b7e5b98de6017ff3e3c059536f974471fe62e0f224eba8f96352a8ee51befbf4c31c88ad0fc8ff4e9d9da174a455a1c30fd61ac977145d3677a08167d508fae207f9458a9b19d4ceec2be30506e2d70cc0362c2bcdb0f73d63fa5e79f9b2901bc870ac8b2a264d50e1862ea177eb587bcd16ceb7d66f96f198cadec3f644af4d3cbe478bc1665818401f89107053d1750047fb7cfc47938bec2cd006db9c176ce337e41160077e353f87ab319e5b9df92282916ef99334c067f6ca20c3d7cbc12b95180b7bba762993a4dbdf4242032da8865988183738d279918906c3357701d74e5d8f5142315ae8f6d0f93537abc3545118e953f983317657a9d8b86e4305ea49e10f80ea07dc7ea7321b32c",
                          "publicKey": "0xb231b19de641f678d250623b2b76099ab4bbd67aac19dcf42ded946831e3366d2a20af0fd9e841197e7e64d7639da4518b76c353db480087e21d55b470f24a180d6d6c8265bf3895e2e4e4e54b8ca9334d62b22feeeed8e77e54bfbc8fae6b62",
                          "name": "0x75b2ac401efd21e60e84a69288da6fff28c7badaae885e417f35055a4e10cb514855f68a0ae18bf42861426c9fc34af13df2f2d04dc68933af78bf3fc396953f301b95f6d6af54ec9fc871c292096e45b91e836063f128c2d1469adbee49bc9b7d62985a858801e4df2cb77eb41ee7b50a8a4e5afb5b585f9034a2808f81bd95b9a3fbdd2579331023f1816a1ecbe7a31e386721a72e3d0ff6087326fba8442dfd22d1182c85906d796e697231c2d7d4a888ae256c79a9019974a4c729d981f3e554f48895e27fe8f45da46bc48c35cc74ae5a31dfea8baa1334fa7f106cdc4ec54452f39c823fa0af97769217cc16c78eb7d0c494c26d2f286f09a507bd04cb15963270bffefb28258176d9e10b7aaad76cdd86e0fe49437eb83c1c0650cb5920e32dc54f3a21a70308b7312b47ce57ef72c2c19eba5027612128b747e80b88c912d7fc10177e67beda0ed5bb8fdfc268bfa5a5c700da953c56bcc79b9186da99ee19a6fa954f44bdcbc7c7f4d208fb750bad587d5513fbaccd511b9b6e0cd798120de87b9c0c410b3b85c75a8a0f469d9973a1ec4c86982cf4fe1a2be21a9206aaabb1ad2fafa628d5156d2ec99ee30fc0ddb9dca6a4cd3a7987227315ceeaa832909853cabaf33c976b59cf5ed9643781d92ab769c0d0aa3bcef40b41b4b3e6fc5a00c9dfbf794047d9cfb97d9d669d00520b6492760a08dba65b0fd7e6d0"
                        }
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
