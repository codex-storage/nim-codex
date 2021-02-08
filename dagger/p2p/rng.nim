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
