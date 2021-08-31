## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import bigints
export bigints

func zero*(T: typedesc): T {.inline.} =
  bigints.zero

func one*(T: typedesc): T {.inline.} =
  bigints.one

func mulmod*(a, b, m: BigInt): BigInt =
  (a * b) mod m

proc powmod*(b, e, m: BigInt): BigInt =
  assert e >= 0
  var e = e
  var b = b
  result = bigints.one
  while e > 0:
    if e mod 2 == 1:
      result = (result * b) mod m
    e = e div 2
    b = (b.pow 2) mod m

proc fromBytesBE*(nptr: openArray[byte], nlen: int): BigInt =
  result = bigints.zero
  for i in 0 ..< nlen:
    result = result * 256 + cast[int32](nptr[i])

proc to256BytesBE*(n: BigInt): array[256, byte] =
  var nn = n

  let nlen = 256
  for i in 0 ..< nlen:
    result[nlen - 1 - i] = cast[uint8](nn.limbs[0] mod 256)
    nn = nn div 256
    # if nn == 0:
    #   break
