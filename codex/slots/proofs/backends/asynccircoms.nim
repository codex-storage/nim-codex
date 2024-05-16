import std/sequtils

import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

import ../../types

import ./circomcompat

const
  CompletionTimeout = 1.seconds
    # Maximum await time for completition after receiving a signal
  CompletionRetryDelay = 10.millis

type
  AsyncCircomCompat* = object
    params*: CircomCompatParams

  # Args objects are missing seq[seq[byte]] field, to avoid unnecessary data copy
  ProveTaskArgs = object
    signal: ThreadSignalPtr
    params: CircomCompatParams

  ProveTaskResult = object
    AnyProofInputs, AnyProof

proc proveTask[H](args: ProveTaskArgs, data: ProofInputs[H]): EncodeTaskResult =
  discard

proc prove*[H](
    self: AsyncCircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =
  ## Generates proof using circom-compat asynchronously
  ##
  discard

proc verify*[H](
    self: AsyncCircomCompat, proof: CircomProof, inputs: ProofInputs[H]
): Future[?!bool] {.async.} =
  ## Verify a proof using a ctx
  ##
  discard

proc init*(_: type AsyncCircomCompat, params: CircomCompatParams): AsyncCircomCompat =
  ## Create a new async circom
  ##
  AsyncCircomCompat(params)
