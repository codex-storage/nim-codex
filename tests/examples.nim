import std/random
import std/sequtils
import std/times
import std/typetraits

import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/units

import pkg/chronos
import pkg/stew/byteutils
import pkg/stint

import ./codex/helpers/randomchunker

export randomchunker
export units

proc exampleString*(length: int): string =
  let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = newString(length) # Create a new empty string with a given length
  for i in 0 ..< length:
    result[i] = chars[rand(chars.len - 1)]
      # Generate a random index and set the string's character

proc example*[T: SomeInteger](_: type T): T =
  rand(T)

proc example*[T, N](_: type array[N, T]): array[N, T] =
  for item in result.mitems:
    item = T.example

proc example*[T](_: type seq[T]): seq[T] =
  let length = uint8.example.int
  newSeqWith(length, T.example)

proc example*(_: type UInt256): UInt256 =
  UInt256.fromBytesBE(array[32, byte].example)

proc example*[T: distinct](_: type T): T =
  type baseType = T.distinctBase
  T(baseType.example)

proc example*(_: type RandomChunker, blocks: int): Future[seq[byte]] {.async.} =
  let rng = Rng.instance()
  let chunker = RandomChunker.new(
    rng, size = DefaultBlockSize * blocks.NBytes, chunkSize = DefaultBlockSize
  )
  var data: seq[byte]
  while (let moar = await chunker.getBytes(); moar != []):
    data.add moar
  return data

proc example*(_: type RandomChunker): Future[string] {.async.} =
  await RandomChunker.example(3)
