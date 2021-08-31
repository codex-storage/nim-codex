## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import stint
export stint

type BigInt* = StUInt[4096] #TODO: check why 2048 is not enough

proc fromBytesBE*(x: openArray[byte], l: int): BigInt = 
  result = BigInt.fromBytesBE(x[0..l-1])

proc to256BytesBE*(msg: BigInt): array[256, byte] =
  stuint(msg, 2048).toBytesBE()

proc initBigInt*(n: SomeInteger): (BigInt) = 
  result = stuint(n, BigInt.bits)
