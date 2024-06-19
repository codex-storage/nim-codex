import std/sequtils

import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

import ./circomcompat
import ../../errors
import ../../logutils

logScope:
  topics = "codex asyncprover"

type
  ProverArgs[H] = object
    circom: CircomCompat
    data: ProofInputs[H]

  VerifierArgs[H] = object
    circom: CircomCompat
    proof: CircomProof
    inputs: ProofInputs[H]

const
  CompletitionTimeout = 1.seconds # Maximum await time for completition after receiving a signal
  CompletitionRetryDelay = 10.millis

proc awaitResult[T](signal: ThreadSignalPtr, handle: Flowvar[T]): Future[?!T] {.async.} =
  await wait(signal)

  var
    res: T
    awaitTotal: Duration
  while awaitTotal < CompletitionTimeout:
      if handle.tryComplete(res):
        return success(res)
      else:
        awaitTotal += CompletitionRetryDelay
        await sleepAsync(CompletitionRetryDelay)

  return failure("Task signaled finish but didn't return any result within " & $CompletitionRetryDelay)

proc asyncProve*[H](
  tp: Taskpool,
  backend: CircomCompat,
  input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =

  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  try:
    echo "test"
  finally:
    if err =? signal.close().mapFailure.errorOption():
      error "Error closing signal", msg = $err.msg


proc asyncVerify*[H](
  tp: Taskpool,
  self: CircomCompat,
  proof: CircomProof,
  inputs: ProofInputs[H]
): Future[?!bool] {.async.} =
  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  try:
    echo "test"
  finally:
    if err =? signal.close().mapFailure.errorOption():
      error "Error closing signal", msg = $err.msg