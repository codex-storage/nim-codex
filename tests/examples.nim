import std/random
import pkg/stint

proc example*[T: SomeInteger](_: type T): T =
  rand(T)

proc example*[T,N](_: type array[N, T]): array[N, T] =
  for item in result.mitems:
    item = T.example

proc example*(_: type UInt256): UInt256 =
  UInt256.fromBytes(array[32, byte].example)
