## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/stew/results
import pkg/chronos

type
  CodexError* = object of CatchableError # base codex error
  CodexResult*[T] = Result[T, ref CodexError]

template mapFailure*(
  exp: untyped,
  exc: typed = type CodexError): untyped =
  ## Convert `Result[T, E]` to `Result[E, ref CatchableError]`
  ##

  ((exp.mapErr do (e: auto) -> ref CatchableError: (ref exc)(msg: $e)))

template wrapFut*[T, E](self: Result[T, E]): Future[Result[T, E]] =
  let
    fut = newFuture[Result[T, E]]()

  fut.complete(self)
  fut
