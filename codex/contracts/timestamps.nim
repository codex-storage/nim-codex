import pkg/stint
import pkg/contractabi
import ../utils/json
from ../clock import SecondsSince1970

type
  StorageTimestamp* = object
    value: StUint[40]
  StorageDuration* = object
    value: StUint[40]
  ProofPeriod* = object
    value: StUint[40]

func u40*(duration: StorageDuration): StUint[40] =
  duration.value

func u40*(duration: StorageTimestamp): StUint[40] =
  duration.value

func u40*(period: ProofPeriod): StUint[40] =
  period.value

func u64*(duration: StorageDuration): uint64 =
  duration.value.truncate(uint64)

func u64*(timestamp: StorageTimestamp): uint64 =
  timestamp.value.truncate(uint64)

func u64*(period: ProofPeriod): uint64 =
  period.value.truncate(uint64)

func u256*(timestamp: StorageTimestamp): UInt256 =
  timestamp.value.stuint(256)

func u256*(duration: StorageDuration): UInt256 =
  duration.value.stuint(256)

proc toSecondsSince1970*(timestamp: StorageTimestamp): SecondsSince1970 =
  timestamp.value.truncate(int64)

func `'StorageDuration`*(value: static string): StorageDuration =
  const parsed = parse(value, StUint[40])
  StorageDuration(value: parsed)

func `'StorageTimestamp`*(value: static string): StorageTimestamp =
  const parsed =parse(value, StUint[40])
  StorageTimestamp(value: parsed)

func init*(_: type StorageDuration, value: StUint[40]): StorageDuration =
  StorageDuration(value: value)

func init*(_: type StorageDuration, value: uint32 | uint16 | uint8): StorageDuration =
  StorageDuration.init(value.stuint(40))

func init*(_: type StorageTimestamp, value: StUint[40]): StorageTimestamp =
  StorageTimestamp(value: value)

func init*(_: type StorageTimestamp, value: uint32 | uint16 | uint8): StorageTimestamp =
  StorageTimestamp.init(value.stuint(40))

func init*(_: type StorageTimestamp, value: SecondsSince1970): StorageTimestamp =
  # The maximum timestamp is 2^40-1 seconds after 1970, which is the year 36,835
  const maximum = StUint[40].high.truncate(SecondsSince1970)
  if value > maximum:
    # make sure that we don't wrap around to a time in the past
    return StorageTimestamp.init(maximum.stuint(40))
  StorageTimestamp.init(value.stuint(40))

func init*(_: type ProofPeriod, value: StUint[40]): ProofPeriod =
  ProofPeriod(value: value)

func `*`*(a: StorageDuration, b: uint32 | uint16 | uint8): StorageDuration =
  StorageDuration.init(a.value * b.stuint(40))

func `+`*(a: StorageTimestamp, b: StorageDuration): StorageTimestamp =
  StorageTimestamp(value: a.value + b.value)

func `+`*(a: StorageTimestamp, b: uint32 | uint16 | uint8): StorageTimestamp =
  StorageTimestamp(value: a.value + b.stuint(40))

func `+`*(a: StorageDuration, b: StorageDuration): StorageDuration =
  StorageDuration(value: a.value + b.value)

func `+`*(a: StorageDuration, b: uint32 | uint16 | uint8): StorageDuration =
  StorageDuration(value: a.value + b.stuint(40))

func `+`*(a: ProofPeriod, b: uint32 | uint16 | uint8): ProofPeriod =
  ProofPeriod(value: a.value + b.stuint(40))

func `-`*(a: StorageTimestamp, b: uint32 | uint16 | uint8): StorageTimestamp =
  StorageTimestamp(value: a.value - b.stuint(40))

func `-`*(a: StorageDuration, b: StorageDuration): StorageDuration =
  StorageDuration(value: a.value - b.value)

func `-`*(a: StorageDuration, b: uint32 | uint16 | uint8): StorageDuration =
  StorageDuration(value: a.value - b.stuint(40))

func `-`*(a: ProofPeriod, b: uint32 | uint16 | uint8): ProofPeriod =
  ProofPeriod(value: a.value - b.stuint(40))

func `+=`*(a: var StorageTimestamp, b: StorageDuration): StorageTimestamp =
  a.value += b.value

func `+=`*[T: StorageDuration | StorageTimestamp](a: var T, b: T) =
  a.value += b.value

func `-=`*[T: StorageDuration | StorageTimestamp](a: var T, b: T) =
  a.value -= b.value

func `<`*(a, b: StorageDuration | StorageTimestamp): bool =
  a.value < b.value

func `>`*(a, b: StorageDuration | StorageTimestamp): bool =
  a.value > b.value

func `<=`*(a, b: StorageDuration | StorageTimestamp): bool =
  a.value <= b.value

func `>=`*(a, b: StorageDuration | StorageTimestamp): bool =
  a.value >= b.value

func until*(earlier, later: StorageTimestamp): StorageDuration =
  doAssert earlier <= later
  StorageDuration.init(later.u40 - earlier.u40)

func solidityType*(_: type StorageDuration): string =
  "uint40"

func solidityType*(_: type StorageTimestamp): string =
  "uint40"

func solidityType*(_: type ProofPeriod): string =
  "uint40"

func encode*(encoder: var AbiEncoder, timestamp: StorageDuration) =
  encoder.write(timestamp.value)

func encode*(encoder: var AbiEncoder, timestamp: StorageTimestamp) =
  encoder.write(timestamp.value)

func encode*(encoder: var AbiEncoder, period: ProofPeriod) =
  encoder.write(period.value)

func decode*(decoder: var AbiDecoder, T: type StorageDuration): ?!T =
  let value = ?decoder.read(T.value)
  success T(value: value)

func decode*(decoder: var AbiDecoder, T: type StorageTimestamp): ?!T =
  let value = ?decoder.read(T.value)
  success T(value: value)

func decode*(decoder: var AbiDecoder, T: type ProofPeriod): ?!T =
  let value = ?decoder.read(T.value)
  success T(value: value)

func `%`*(value: StorageDuration | StorageTimestamp | ProofPeriod): JsonNode =
  %value.value

func fromJson*(_: type StorageDuration, json: JsonNode): ?!StorageDuration =
  success StorageDuration(value: ? StUint[40].fromJson(json))

func fromJson*(_: type StorageTimestamp, json: JsonNode): ?!StorageTimestamp =
  success StorageTimestamp(value: ? StUint[40].fromJson(json))

func fromJson*(_: type ProofPeriod, json: JsonNode): ?!ProofPeriod =
  success ProofPeriod(value: ? StUint[40].fromJson(json))

