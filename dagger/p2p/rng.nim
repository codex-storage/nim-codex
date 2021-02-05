## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/libp2p/crypto/crypto
import pkg/bearssl

type
  Rng* = RandomNumberGenerator
  RandomNumberGenerator = ref BrHmacDrbgContext

var rng {.threadvar.}: Rng

proc instance*(t: type Rng): Rng =
  if rng.isNil:
    rng = newRng()
  rng
