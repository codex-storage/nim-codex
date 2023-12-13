import std/json
import std/options
import std/nre
import std/strutils
import std/unittest
import pkg/codex/blocktype
import pkg/codex/conf
import pkg/codex/contracts/requests
import pkg/codex/logutils
import pkg/codex/purchasing/purchaseid
import pkg/codex/units
import pkg/codex/utils/json
import pkg/libp2p/cid
import pkg/libp2p/multiaddress
import pkg/stew/byteutils
import pkg/stint
import ../checktest
import ../examples
import ./examples

export logutils

logStream testlines[textlines[notimestamps,dynamic]]
logStream testjson[json[notimestamps,dynamic]]

type
  ObjectType = object
    a: string
  DistinctType {.borrow: `.`.} = distinct ObjectType
  RefType = ref object
    a: string

# must be defined at the top-level
proc `$`*(t: ObjectType): string = "used `$`"
logutils.formatIt(ObjectType): "formatted_" & it.a
logutils.formatIt(RefType): "formatted_" & it.a
logutils.formatIt(DistinctType): "formatted_" & it.a

checksuite "Test logging outputLines":
  var outputLines: string
  var outputJson: string

  proc writeToLines(logLevel: LogLevel, msg: LogOutputStr) =
    outputLines &= stripAnsi(msg) # nocolors in the stream definition doesn't seem to work

  proc writeToJson(logLevel: LogLevel, msg: LogOutputStr) =
    outputJson &= stripAnsi(msg)

  setup:
    outputLines = ""
    outputJson = ""
    testlines.outputs[0].writer = writeToLines
    testjson.outputs[0].writer = writeToJson

  template logged(prop, expected): auto =
    let regex = prop & """\=\"?""" & expected.escapeRe & """\"?"""
    outputLines.contains(re(regex))

  template loggedJson(prop, expected): auto =
    let json = $ parseJson(outputJson){prop}
    json == expected

  template log(val) =
    testlines.trace "test", val
    testjson.trace "test", val

  test "logs objects":
    let t = ObjectType(a: "a")
    log t
    check logged("t", "formatted_a")
    check loggedJson("t", "\"formatted_a\"")

  test "logs sequences of objects":
    let t1 = ObjectType(a: "a")
    let t2 = ObjectType(a: "b")
    let t = @[t1, t2]
    log t
    check logged("t", "@[formatted_a, formatted_b]")
    check loggedJson("t", "[\"formatted_a\",\"formatted_b\"]")

  test "logs ref types":
    let t = RefType(a: "a")
    log t
    check logged("t", "formatted_a")
    check loggedJson("t", "\"formatted_a\"")

  test "logs sequences of ref types":
    let t1 = RefType(a: "a")
    let t2 = RefType(a: "b")
    let t = @[t1, t2]
    log t
    check logged("t", "@[formatted_a, formatted_b]")
    check loggedJson("t", "[\"formatted_a\",\"formatted_b\"]")

  test "logs distinct types":
    let t = DistinctType(ObjectType(a: "a"))
    log t
    check logged("t", "formatted_a")
    check loggedJson("t", "\"formatted_a\"")

  test "logs sequences of distinct types":
    let t1 = DistinctType(ObjectType(a: "a"))
    let t2 = DistinctType(ObjectType(a: "b"))
    let t = @[t1, t2]
    log t
    check logged("t", "@[formatted_a, formatted_b]")
    check loggedJson("t", "[\"formatted_a\",\"formatted_b\"]")

  test "logs Option types":
    let t = some ObjectType(a: "a")
    log t
    check logged("t", "some(formatted_a)")
    check loggedJson("t", """{"val":"formatted_a","has":true}""")

  test "logs sequences of Option types":
    let t1 = some ObjectType(a: "a")
    let t2 = none ObjectType
    let t = @[t1, t2]
    log t
    check logged("t", "@[some(formatted_a), none(ObjectType)]")
    check loggedJson("t", """[{"val":"formatted_a","has":true},{"val":"formatted_","has":false}]""")

  test "can define `$` override for T":
    let o = ObjectType()
    check $o == "used `$`"

  test "logs NByte correctly":
    let nb = 12345.NBytes
    log nb
    check logged("nb", "12345\'NByte")
    check loggedJson("nb", "\"12345\'NByte\"")

  test "logs BlockAddress correctly":
    let cid = Cid.init("zb2rhgsDE16rLtbwTFeNKbdSobtKiWdjJPvKEuPgrQAfndjU1").tryGet
    let ba = BlockAddress.init(cid, 0)
    log ba
    check logged("ba", "treeCid: zb2*fndjU1, index: 0")
    check loggedJson("ba", "\"treeCid: zb2*fndjU1, index: 0\"")

  test "logs Cid correctly":
    let cid = Cid.init("zb2rhmfWaXASbyi15iLqbz5yp3awnSyecpt9jcFnc2YA5TgiD").tryGet
    log cid
    check logged("cid", "zb2*A5TgiD")

  test "logs StUint correctly":
    let stint = 12345678901234.u256
    log stint
    check logged("stint", "12345678901234")

  test "logs EthAddress correctly":
    let address = EthAddress.fromHex("0xf75e076f650cd51dbfa0fd9c465d5037f22e1b1b")
    log address
    check logged("address", "0xf75e..1b1b")

  test "logs PurchaseId correctly":
    let id = PurchaseId.fromHex("0x712003bdfc0db9abf21e7fbb7119cd52ff221c96714d21d39e782d7c744d3dea")
    log id
    check logged("id", "0x7120..3dea")

  test "logs RequestId correctly":
    let id = RequestId.fromHex("0x712003bdfc0db9abf21e7fbb7119cd52ff221c96714d21d39e782d7c744d3dea")
    log id
    check logged("id", "0x7120..3dea")

  test "logs seq[RequestId] correctly":
    let id = RequestId.fromHex("0x712003bdfc0db9abf21e7fbb7119cd52ff221c96714d21d39e782d7c744d3dea")
    let id2 = RequestId.fromHex("0x9ab2c4d102a95d990facb022d67b3c9b39052597c006fddf122bed2cb594c282")
    let ids = @[id, id2]
    log ids
    check logged("ids", "@[0x7120..3dea, 0x9ab2..c282]")
    check loggedJson("ids", """["0x7120..3dea","0x9ab2..c282"]""")

  test "logs SlotId correctly":
    let id = SlotId.fromHex("0x9ab2c4d102a95d990facb022d67b3c9b39052597c006fddf122bed2cb594c282")
    log id
    check logged("id", "0x9ab2..c282")

  test "logs Nonce correctly":
    let id = SlotId.fromHex("ce88f368a7b776172ebd29a212456eb66acb60f169ee76eae91935e7fafad6ea")
    log id
    check logged("id", "0xce88..d6ea")

  test "logs MultiAddress correctly":
    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet
    log ma
    check logged("ma", "/ip4/127.0.0.1/tcp/0")

  test "logs seq[MultiAddress] correctly":
    let ma = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet,
               MultiAddress.init("/ip4/127.0.0.2/tcp/1").tryGet]
    log ma
    check logged("ma", "@[/ip4/127.0.0.1/tcp/0, /ip4/127.0.0.2/tcp/1]")
