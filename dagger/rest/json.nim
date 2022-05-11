import std/json
import std/strutils
import pkg/stew/byteutils
import pkg/questionable/results
import ../sales
import ../purchasing

type
  StorageRequestParams* = object
    duration*: UInt256
    maxPrice*: UInt256

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
  let maxPrice = ?catch UInt256.fromHex(json["maxPrice"].getStr)
  success StorageRequestParams(duration: duration, maxPrice: maxPrice)

func `%`*(address: Address): JsonNode =
  % $address

func `%`*(stint: StInt|StUInt): JsonNode =
  %("0x" & stint.toHex)

func `%`*(arr: openArray[byte]): JsonNode =
  %("0x" & arr.toHex)

func `%`*(purchase: Purchase): JsonNode =
  %*{
    "request": %purchase.request,
    "offers": %purchase.offers,
    "selected": %purchase.selected
  }
