## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/stew/results

export results

type
  CodexError* = object of CatchableError # base codex error
  CodexResult*[T] = Result[T, ref CodexError]

proc mapFailure*[T, V, E](
    exp: Result[T, V],
    exc: typedesc[E],
): Result[T, ref E] =
  ## Convert `Result[T, E]` to `Result[E, ref CatchableError]`
  ##

  proc convertToErr(e: V): ref E =
    (ref exc)(msg: $e)
  exp.mapErr(convertToErr)

proc mapFailure*[T, V](exp: Result[T, V]): Result[T, ref CodexError] =
  mapFailure(exp, CodexError)