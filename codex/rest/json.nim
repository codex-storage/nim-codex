import std/json
import std/strutils
import pkg/stew/byteutils
import pkg/questionable/results
import ../sales
import ../purchasing

type
  StorageRequestParams* = object
    duration*: UInt256
    proofProbability*: UInt256
    reward*: UInt256
    collateral*: UInt256
    expiry*: ?UInt256
    nodes*: ?uint
    tolerance*: ?uint

proc fromJson*(_: type Availability, bytes: seq[byte]): ?!Availability =
  let json = ?catch parseJson(string.fromBytes(bytes))
  let size = ?catch UInt256.fromHex(json["size"].getStr)
  let duration = ?catch UInt256.fromHex(json["duration"].getStr)
  let minPrice = ?catch UInt256.fromHex(json["minPrice"].getStr)
  let maxCollateral = ?catch UInt256.fromHex(json["maxCollateral"].getStr)
  success Availability.init(size, duration, minPrice, maxCollateral)

proc fromJson*(_: type StorageRequestParams,
               bytes: seq[byte]): ?! StorageRequestParams =
  let json = ?catch parseJson(string.fromBytes(bytes))
  let duration = ?catch UInt256.fromHex(json["duration"].getStr)
  let proofProbability = ?catch UInt256.fromHex(json["proofProbability"].getStr)
  let reward = ?catch UInt256.fromHex(json["reward"].getStr)
  let collateral = ?catch UInt256.fromHex(json["collateral"].getStr)
  let expiry = UInt256.fromHex(json["expiry"].getStr).catch.option
  let nodes = strutils.fromHex[uint](json["nodes"].getStr).catch.option
  let tolerance = strutils.fromHex[uint](json["tolerance"].getStr).catch.option
  success StorageRequestParams(
    duration: duration,
    proofProbability: proofProbability,
    reward: reward,
    collateral: collateral,
    expiry: expiry,
    nodes: nodes,
    tolerance: tolerance
  )

func `%`*(address: Address): JsonNode =
  % $address

func `%`*(stint: StInt|StUint): JsonNode =
  %("0x" & stint.toHex)

func `%`*(arr: openArray[byte]): JsonNode =
  %("0x" & arr.toHex)

func `%`*(id: RequestId | SlotId | Nonce | AvailabilityId): JsonNode =
  % id.toArray

func `%`*(purchase: Purchase): JsonNode =
  %*{
    "state": (purchase.state as PurchaseState).?description |? "none",
    "error": purchase.error.?msg,
    "request": purchase.request,
    "requestId": purchase.requestId
  }
