
import std/json except `%`, `%*`
import std/macros
import std/options
import std/strutils
import std/strformat
import std/tables
import std/typetraits
import pkg/chronicles
from pkg/libp2p import Cid, init
import pkg/contractabi
import pkg/stew/byteutils
import pkg/stint
import pkg/questionable/results
import ../errors

export json except `%`, `%*`

logScope:
  topics = "json serialization"

type
  SerializationError = object of CodexError
  UnexpectedKindError = object of SerializationError

template serialize* {.pragma.}

proc newUnexpectedKindError(
  expectedType: type,
  expectedKinds: string,
  json: JsonNode
): ref UnexpectedKindError =
  let kind = if json.isNil: "nil"
             else: $json.kind
  newException(UnexpectedKindError,
    &"deserialization to {$expectedType} failed: expected {expectedKinds} " &
    &"but got {kind}")

proc newUnexpectedKindError(
  expectedType: type,
  expectedKinds: set[JsonNodeKind],
  json: JsonNode
): ref UnexpectedKindError =
  newUnexpectedKindError(expectedType, $expectedKinds, json)

proc newUnexpectedKindError(
  expectedType: type,
  expectedKind: JsonNodeKind,
  json: JsonNode
): ref UnexpectedKindError =
  newUnexpectedKindError(expectedType, {expectedKind}, json)

template expectJsonKind(
  expectedType: type,
  expectedKinds: set[JsonNodeKind],
  json: JsonNode
) =
  if json.isNil or json.kind notin expectedKinds:
    return failure(newUnexpectedKindError(expectedType, expectedKinds, json))

template expectJsonKind(
  expectedType: type,
  expectedKind: JsonNodeKind,
  json: JsonNode
) =
  expectJsonKind(expectedType, {expectedKind}, json)

proc fromJson*(
  T: type enum,
  json: JsonNode
): ?!T =
  expectJsonKind(string, JString, json)
  catch parseEnum[T](json.str)

proc fromJson*(
  _: type string,
  json: JsonNode
): ?!string =
  if json.isNil:
    let err = newException(ValueError, "'json' expected, but was nil")
    return failure(err)
  elif json.kind == JNull:
    return success("null")
  elif json.isNil or json.kind != JString:
    return failure(newUnexpectedKindError(string, JString, json))
  catch json.getStr

proc fromJson*(
  _: type bool,
  json: JsonNode
): ?!bool =
  expectJsonKind(bool, JBool, json)
  catch json.getBool

proc fromJson*(
  _: type int,
  json: JsonNode
): ?!int =
  expectJsonKind(int, JInt, json)
  catch json.getInt

proc fromJson*[T: SomeInteger](
  _: type T,
  json: JsonNode
): ?!T =
  when T is uint|uint64 or (not defined(js) and int.sizeof == 4):
    expectJsonKind(T, {JInt, JString}, json)
    case json.kind
    of JString:
      let x = parseBiggestUInt(json.str)
      return success cast[T](x)
    else:
      return success T(json.num)
  else:
    expectJsonKind(T, {JInt}, json)
    return success cast[T](json.num)

proc fromJson*[T: SomeFloat](
  _: type T,
  json: JsonNode
): ?!T =
  expectJsonKind(T, {JInt, JFloat, JString}, json)
  if json.kind == JString:
    case json.str
    of "nan":
      let b = NaN
      return success T(b)
      # dst = NaN # would fail some tests because range conversions would cause CT error
      # in some cases; but this is not a hot-spot inside this branch and backend can optimize this.
    of "inf":
      let b = Inf
      return success T(b)
    of "-inf":
      let b = -Inf
      return success T(b)
    else:
      let err = newUnexpectedKindError(T, "'nan|inf|-inf'", json)
      return failure(err)
  else:
    if json.kind == JFloat:
      return success T(json.fnum)
    else:
      return success T(json.num)

proc fromJson*(
  _: type seq[byte],
  json: JsonNode
): ?!seq[byte] =
  expectJsonKind(seq[byte], JString, json)
  hexToSeqByte(json.getStr).catch

proc fromJson*[N: static[int], T: array[N, byte]](
  _: type T,
  json: JsonNode
): ?!T =
  expectJsonKind(T, JString, json)
  T.fromHex(json.getStr).catch

proc fromJson*[T: distinct](
  _: type T,
  json: JsonNode
): ?!T =
  success T(? T.distinctBase.fromJson(json))

proc fromJson*[N: static[int], T: StUint[N]](
  _: type T,
  json: JsonNode
): ?!T =
  expectJsonKind(T, JString, json)
  catch parse(json.getStr, T)

proc fromJson*[T](
  _: type Option[T],
  json: JsonNode
): ?! Option[T] =
  if json.isNil or json.kind == JNull:
    return success(none T)
  without val =? T.fromJson(json), error:
    return failure(error)
  success(val.some)

proc fromJson*(
  _: type Cid,
  json: JsonNode
): ?!Cid =
  expectJsonKind(Cid, JString, json)
  Cid.init(json.str).mapFailure

proc fromJson*[T](
  _: type seq[T],
  json: JsonNode
): ?! seq[T] =
  expectJsonKind(seq[T], JArray, json)
  var arr: seq[T] = @[]
  for elem in json.elems:
    arr.add(? T.fromJson(elem))
  success arr

proc fromJson*[T: ref object or object](
  _: type T,
  json: JsonNode
): ?!T =
  expectJsonKind(T, JObject, json)
  var res = when type(T) is ref: T.new() else: T.default

  # Leave this in, it's good for debugging:
  # trace "deserializing object", to = $T, json
  for name, value in fieldPairs(when type(T) is ref: res[] else: res):
    if json{name} != nil:
      without parsed =? type(value).fromJson(json{name}), e:
        error "error deserializing field",
          field = $T & "." & name,
          json = json{name},
          error = e.msg
        return failure(e)
      value = parsed
  success(res)

proc fromJson*[T: object](
  _: type T,
  bytes: seq[byte]
): ?!T =
  let json = ?catch parseJson(string.fromBytes(bytes))
  T.fromJson(json)

proc fromJson*[T: ref object](
  _: type T,
  bytes: seq[byte]
): ?!T =
  let json = ?catch parseJson(string.fromBytes(bytes))
  T.fromJson(json)

func `%`*(s: string): JsonNode = newJString(s)

func `%`*(n: uint): JsonNode =
  if n > cast[uint](int.high):
    newJString($n)
  else:
    newJInt(BiggestInt(n))

func `%`*(n: int): JsonNode = newJInt(n)

func `%`*(n: BiggestUInt): JsonNode =
  if n > cast[BiggestUInt](BiggestInt.high):
    newJString($n)
  else:
    newJInt(BiggestInt(n))

func `%`*(n: BiggestInt): JsonNode = newJInt(n)

func `%`*(n: float): JsonNode =
  if n != n: newJString("nan")
  elif n == Inf: newJString("inf")
  elif n == -Inf: newJString("-inf")
  else: newJFloat(n)

func `%`*(b: bool): JsonNode = newJBool(b)

func `%`*(keyVals: openArray[tuple[key: string, val: JsonNode]]): JsonNode =
  if keyVals.len == 0: return newJArray()
  let jObj = newJObject()
  for key, val in items(keyVals): jObj.fields[key] = val
  jObj

template `%`*(j: JsonNode): JsonNode = j

func `%`*[T](table: Table[string, T]|OrderedTable[string, T]): JsonNode =
  let jObj = newJObject()
  for k, v in table: jObj[k] = ? %v
  jObj

func `%`*[T](opt: Option[T]): JsonNode =
  if opt.isSome: %(opt.get) else: newJNull()

func `%`*[T: object](obj: T): JsonNode =
  let jsonObj = newJObject()
  for name, value in obj.fieldPairs:
    when value.hasCustomPragma(serialize):
      jsonObj[name] = %value
  jsonObj

func `%`*[T: ref object](obj: T): JsonNode =
  let jsonObj = newJObject()
  for name, value in obj[].fieldPairs:
    when value.hasCustomPragma(serialize):
      jsonObj[name] = %(value)
  jsonObj

proc `%`*(o: enum): JsonNode = % $o

func `%`*(stint: StInt|StUint): JsonNode = %stint.toString

func `%`*(cstr: cstring): JsonNode = % $cstr

func `%`*(arr: openArray[byte]): JsonNode = % arr.to0xHex

func `%`*[T](elements: openArray[T]): JsonNode =
  let jObj = newJArray()
  for elem in elements: jObj.add(%elem)
  jObj

func `%`*[T: distinct](id: T): JsonNode =
  type baseType = T.distinctBase
  % baseType(id)

func toJson*(obj: object): string = $(%obj)
func toJson*(obj: ref object): string = $(%obj)

func toJson*[T: object](elements: openArray[T]): string =
  let jObj = newJArray()
  for elem in elements: jObj.add(%elem)
  $jObj

func toJson*[T: ref object](elements: openArray[T]): string =
  let jObj = newJArray()
  for elem in elements: jObj.add(%elem)
  $jObj

proc toJsnImpl(x: NimNode): NimNode =
  case x.kind
  of nnkBracket: # array
    if x.len == 0: return newCall(bindSym"newJArray")
    result = newNimNode(nnkBracket)
    for i in 0 ..< x.len:
      result.add(toJsnImpl(x[i]))
    result = newCall(bindSym("%", brOpen), result)
  of nnkTableConstr: # object
    if x.len == 0: return newCall(bindSym"newJObject")
    result = newNimNode(nnkTableConstr)
    for i in 0 ..< x.len:
      x[i].expectKind nnkExprColonExpr
      result.add newTree(nnkExprColonExpr, x[i][0], toJsnImpl(x[i][1]))
    result = newCall(bindSym("%", brOpen), result)
  of nnkCurly: # empty object
    x.expectLen(0)
    result = newCall(bindSym"newJObject")
  of nnkNilLit:
    result = newCall(bindSym"newJNull")
  of nnkPar:
    if x.len == 1: result = toJsnImpl(x[0])
    else: result = newCall(bindSym("%", brOpen), x)
  else:
    result = newCall(bindSym("%", brOpen), x)

macro `%*`*(x: untyped): JsonNode =
  ## Convert an expression to a JsonNode directly, without having to specify
  ## `%` for every element.
  result = toJsnImpl(x)
