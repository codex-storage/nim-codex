import pkg/stint
import pkg/contractabi
import ../utils/json
import ./timestamps

type
  TokensPerSecond* = object
    value: StUint[96]

  Tokens* = object
    value: StUint[128]

func u256*(tokensPerSecond: TokensPerSecond): UInt256 =
  tokensPerSecond.value.stuint(256)

func u256*(tokens: Tokens): UInt256 =
  tokens.value.stuint(256)

func `'TokensPerSecond`*(value: static string): TokensPerSecond =
  const parsed = parse(value, StUint[96])
  TokensPerSecond(value: parsed)

func `'Tokens`*(value: static string): Tokens =
  const parsed = parse(value, UInt128)
  Tokens(value: parsed)

func init*(_: type TokensPerSecond, value: StUint[96]): TokensPerSecond =
  TokensPerSecond(value: value)

func init*(_: type TokensPerSecond, value: SomeUnsignedInt): TokensPerSecond =
  TokensPerSecond.init(value.stuint(96))

func init*(_: type Tokens, value: UInt128): Tokens =
  Tokens(value: value)

func init*(_: type Tokens, value: SomeUnsignedInt): Tokens =
  Tokens.init(value.stuint(128))

func `*`*(a: TokensPerSecond, b: SomeUnsignedInt): TokensPerSecond =
  TokensPerSecond(value: a.value * b.stuint(96))

func `*`*(a: TokensPerSecond, b: StorageDuration): Tokens =
  Tokens(value: a.value.stuint(128) * b.u40.stuint(128))

func `*`*(a: Tokens, b: SomeUnsignedInt): Tokens =
  Tokens(value: a.value * b.stuint(128))

func `div`*(a: Tokens, b: SomeUnsignedInt): Tokens =
  Tokens(value: a.value div b.stuint(128))

func `+`*(a, b: Tokens): Tokens =
  Tokens(value: a.value + b.value)

func `+`*(a: Tokens, b: SomeUnsignedInt): Tokens =
  Tokens(value: a.value + b.u128)

func `+`*(a: TokensPerSecond, b: SomeUnsignedInt): TokensPerSecond =
  TokensPerSecond(value: a.value + b.stuint(96))

func `-`*(a, b: Tokens): Tokens =
  Tokens(value: a.value - b.value)

func `+=`*[T: Tokens | TokensPerSecond](a: var T, b: T) =
  a.value += b.value

func `-=`*[T: Tokens | TokensPerSecond](a: var T, b: T) =
  a.value -= b.value

func `<`*(a, b: Tokens | TokensPerSecond): bool =
  a.value < b.value

func `>`*(a, b: Tokens | TokensPerSecond): bool =
  a.value > b.value

func `<=`*(a, b: Tokens | TokensPerSecond): bool =
  a.value <= b.value

func `>=`*(a, b: Tokens | TokensPerSecond): bool =
  a.value >= b.value

func solidityType*(_: type TokensPerSecond): string =
  "uint96"

func solidityType*(_: type Tokens): string =
  "uint128"

func encode*(encoder: var AbiEncoder, tokensPerSecond: TokensPerSecond) =
  encoder.write(tokensPerSecond.value)

func encode*(encoder: var AbiEncoder, tokens: Tokens) =
  encoder.write(tokens.value)

func decode*(decoder: var AbiDecoder, T: type TokensPerSecond): ?!T =
  let value = ?decoder.read(T.value)
  success T(value: value)

func decode*(decoder: var AbiDecoder, T: type Tokens): ?!T =
  let value = ?decoder.read(T.value)
  success T(value: value)

func `%`*(value: TokensPerSecond | Tokens): JsonNode =
  %value.value

func fromJson*(_: type TokensPerSecond, json: JsonNode): ?!TokensPerSecond =
  success TokensPerSecond(value: ?StUint[96].fromJson(json))

func fromJson*(_: type Tokens, json: JsonNode): ?!Tokens =
  success Tokens(value: ?UInt128.fromJson(json))
