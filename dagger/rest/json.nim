import std/json
import std/strutils
import pkg/stew/byteutils
import pkg/questionable/results
import ../sales

func fromHex(T: type SomeInteger, s: string): T =
  strutils.fromHex[T](s)

proc fromJson*(_: type Availability, bytes: seq[byte]): ?!Availability =
  let json = ?catch parseJson(string.fromBytes(bytes))
  let size = ?catch UInt256.fromHex(json["size"].getStr)
  let duration = ?catch uint64.fromHex(json["duration"].getStr)
  let minPrice = ?catch uint64.fromHex(json["minPrice"].getStr)
  success Availability.init(size, duration, minPrice)
