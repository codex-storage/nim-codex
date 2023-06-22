import std/json
import std/strutils
import pkg/stew/byteutils
import pkg/questionable/results
import ../sales
import ../purchasing
import ../utils/stintutils

export json

type
  StorageRequestParams* = object
    duration*: UInt256
    proofProbability*: UInt256
    reward*: UInt256
    collateral*: UInt256
    expiry*: ?UInt256
    nodes*: ?uint
    tolerance*: ?uint

proc fromJson*(
    _: type Availability,
    bytes: seq[byte]
): ?!Availability =
  let json = ?catch parseJson(string.fromBytes(bytes))
  let size = ?catch UInt256.fromDecimal(json["size"].getStr)
  let duration = ?catch UInt256.fromDecimal(json["duration"].getStr)
  let minPrice = ?catch UInt256.fromDecimal(json["minPrice"].getStr)
  let maxCollateral = ?catch UInt256.fromDecimal(json["maxCollateral"].getStr)
  success Availability.init(size, duration, minPrice, maxCollateral)

proc fromJson*(
    _: type StorageRequestParams,
    bytes: seq[byte]
): ?! StorageRequestParams =
  let json = ?catch parseJson(string.fromBytes(bytes))
  let duration = ?catch UInt256.fromDecimal(json["duration"].getStr)
  let proofProbability = ?catch UInt256.fromDecimal(json["proofProbability"].getStr)
  let reward = ?catch UInt256.fromDecimal(json["reward"].getStr)
  let collateral = ?catch UInt256.fromDecimal(json["collateral"].getStr)
  let expiry = UInt256.fromDecimal(json["expiry"].getStr).catch.option
  let nodes = parseUInt(json["nodes"].getStr).catch.option
  let tolerance = parseUInt(json["tolerance"].getStr).catch.option
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

func `%`*(stint: StInt|StUint): JsonNode=
  %(stint.toString)

func `%`*(arr: openArray[byte]): JsonNode =
  %("0x" & arr.toHex)

func `%`*(id: RequestId | SlotId | Nonce | AvailabilityId): JsonNode =
  % id.toArray

func `%`*(obj: StorageRequest | Slot): JsonNode =
  let jsonObj = newJObject()
  for k, v in obj.fieldPairs: jsonObj[k] = %v
  jsonObj["id"] = %(obj.id)

  return jsonObj

func `%`*(purchase: Purchase): JsonNode =
  %*{
    "state": purchase.state |? "none",
    "error": purchase.error.?msg,
    "request": purchase.request,
    "requestId": purchase.requestId
  }
