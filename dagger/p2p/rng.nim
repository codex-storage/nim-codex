## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/libp2p
import pkg/bearssl

type
  Rng* = RandomNumberGenerator
  RandomNumberGenerator = ref BrHmacDrbgContext

var rng {.threadvar.}: Rng

proc instance*(t: type Rng): Rng =
  if rng.isNil:
    rng = newRng()
  rng

## Random helpers: similar as in stdlib, but with BrHmacDrbgContext rng
# TODO: Move these somewhere else?
const randMax = 18_446_744_073_709_551_615'u64

proc rand*(rng: Rng, max: Natural): int =
  if max == 0: return 0

  var x: uint64
  while true:
    brHmacDrbgGenerate(addr rng[], addr x, csize_t(sizeof(x)))
    if x < randMax - (randMax mod (uint64(max) + 1'u64)): # against modulo bias
      return int(x mod (uint64(max) + 1'u64))

proc sample*[T](rng: Rng, a: openArray[T]): T =
  result = a[rng.rand(a.high)]

proc shuffle*[T](rng: Rng, a: var openArray[T]) =
  for i in countdown(a.high, 1):
    let j = rng.rand(i)
    swap(a[i], a[j])
