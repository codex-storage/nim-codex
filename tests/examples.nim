import std/random
import std/sequtils
import pkg/stint

proc example*[T: SomeInteger](_: type T): T =
  rand(T)

proc example*[T,N](_: type array[N, T]): array[N, T] =
  for item in result.mitems:
    item = T.example

proc example*[T](_: type seq[T]): seq[T] =
  let length = uint8.example.int
  newSeqWith(length, T.example)

proc example*(_: type UInt256): UInt256 =
  UInt256.fromBytes(array[32, byte].example)
