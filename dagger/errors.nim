## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/stew/results

type
  DaggerError* = object of CatchableError # base dagger error
  DaggerResult*[T] = Result[T, ref DaggerError]

template mapFailure*(
  exp: untyped,
  exc: typed = type DaggerError): untyped =
  ## Convert `Result[T, E]` to `Result[E, ref CatchableError]`
  ##

  ((exp.mapErr do (e: auto) -> ref CatchableError: (ref exc)(msg: $e)))
