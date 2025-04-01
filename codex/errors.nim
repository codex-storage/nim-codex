## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options
import std/sugar
import std/sequtils

import pkg/results
import pkg/chronos
import pkg/questionable/results

export results

type
  CodexError* = object of CatchableError # base codex error
  CodexResult*[T] = Result[T, ref CodexError]

  FinishedFailed*[T] = tuple[success: seq[Future[T]], failure: seq[Future[T]]]

template mapFailure*[T, V, E](
    exp: Result[T, V], exc: typedesc[E]
): Result[T, ref CatchableError] =
  ## Convert `Result[T, E]` to `Result[E, ref CatchableError]`
  ##

  exp.mapErr(
    proc(e: V): ref CatchableError =
      (ref exc)(msg: $e)
  )

template mapFailure*[T, V](exp: Result[T, V]): Result[T, ref CatchableError] =
  mapFailure(exp, CodexError)

# TODO: using a template here, causes bad codegen
func toFailure*[T](exp: Option[T]): Result[T, ref CatchableError] {.inline.} =
  if exp.isSome:
    success exp.get
  else:
    T.failure("Option is None")

proc allFinishedFailed*[T](
    futs: seq[Future[T]]
): Future[FinishedFailed[T]] {.async: (raises: [CancelledError]).} =
  ## Check if all futures have finished or failed
  ##
  ## TODO: wip, not sure if we want this - at the minimum,
  ## we should probably avoid the async transform

  var res: FinishedFailed[T] = (@[], @[])
  await allFutures(futs)
  for f in futs:
    if f.failed:
      res.failure.add f
    else:
      res.success.add f

  return res

proc allFinishedValues*[T](
    futs: seq[Future[T]]
): Future[?!seq[T]] {.async: (raises: [CancelledError]).} =
  ## If all futures have finished, return corresponding values,
  ## otherwise return failure
  ##

  # wait for all futures to be either completed, failed or canceled
  await allFutures(futs)

  let numOfFailed = futs.countIt(it.failed)

  if numOfFailed > 0:
    return failure "Some futures failed (" & $numOfFailed & "))"

  # here, we know there are no failed futures in "futs"
  # and we are only interested in those that completed successfully
  let values = collect:
    for b in futs:
      if b.finished:
        b.value
  return success values
