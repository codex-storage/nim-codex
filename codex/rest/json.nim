import std/json
import std/strutils
import pkg/stew/byteutils
import pkg/questionable/results
import ../sales
import ../purchasing

type
  StorageRequestParams* = object
    duration*: UInt256
    reward*: UInt256
    expiry*: ?UInt256
    nodes*: ?uint
    tolerance*: ?uint

proc fromJson*(_: type Availability, bytes: seq[byte]): ?!Availability =
  let json = ?catch parseJson(string.fromBytes(bytes))
  let size = ?catch UInt256.fromHex(json["size"].getStr)
  let duration = ?catch UInt256.fromHex(json["duration"].getStr)
  let minPrice = ?catch UInt256.fromHex(json["minPrice"].getStr)
  success Availability.init(size, duration, minPrice)

proc fromJson*(_: type StorageRequestParams,
               bytes: seq[byte]): ?! StorageRequestParams =
  let json = ?catch parseJson(string.fromBytes(bytes))
  let duration = ?catch UInt256.fromHex(json["duration"].getStr)
  let reward = ?catch UInt256.fromHex(json["reward"].getStr)
  let expiry = UInt256.fromHex(json["expiry"].getStr).catch.option
  let nodes = strutils.fromHex[uint](json["nodes"].getStr).catch.option
  let tolerance = strutils.fromHex[uint](json["tolerance"].getStr).catch.option
  success StorageRequestParams(
    duration: duration,
    reward: reward,
    expiry: expiry,
    nodes: nodes,
    tolerance: tolerance
  )

func `%`*(address: Address): JsonNode =
  % $address

func `%`*(stint: StInt|StUInt): JsonNode =
  %("0x" & stint.toHex)

func `%`*(arr: openArray[byte]): JsonNode =
  %("0x" & arr.toHex)

func `%`*(purchase: Purchase): JsonNode =
  %*{
    "finished": purchase.finished,
    "error": purchase.error.?msg,
    "request": purchase.request,
  }
