import std/json
import std/strutils
import pkg/stew/byteutils
import pkg/questionable/results
import ../sales

proc fromJson*(_: type Availability, bytes: seq[byte]): ?!Availability =
  let json = ?catch parseJson(string.fromBytes(bytes))
  let size = ?catch UInt256.fromHex(json["size"].getStr)
  let duration = ?catch UInt256.fromHex(json["duration"].getStr)
  let minPrice = ?catch UInt256.fromHex(json["minPrice"].getStr)
  success Availability.init(size, duration, minPrice)
