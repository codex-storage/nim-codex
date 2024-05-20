import std/options

import pkg/taskpools
import pkg/chronicles
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

import ../../types
import ../../../utils/asyncthreads

import ./circomcompat

logScope:
  topics = "codex asyncprover"

type AsyncCircomCompat* = object
  circom*: CircomCompat
  tp*: Taskpool

proc proveTask[H](
    circom: CircomCompat, data: ProofInputs[H], results: SignalQueuePtr[?!CircomProof]
) =
  let proof = circom.prove(data)

  if (let sent = results.send(proof); sent.isErr()):
    error "Error sending proof results", msg = sent.error().msg

proc prove*[H](
    self: AsyncCircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =
  ## Generates proof using circom-compat asynchronously
  ##
  without queue =? newSignalQueue[?!CircomProof](maxItems = 1), err:
    return (?!CircomProof).err(err)

  proc spawnTask() =
    self.tp.spawn proveTask(self.circom, input, queue)

  spawnTask()

  let taskRes = await queue.recvAsync()
  if (let res = queue.release(); res.isErr):
    error "Error releasing proof queue ", msg = res.error().msg
  without proofRes =? taskRes, err:
    return failure(err)
  without proof =? proofRes, err:
    return failure(err)

  success(proof)

proc verifyTask[H](
    circom: CircomCompat,
    proof: CircomProof,
    inputs: ProofInputs[H],
    results: SignalQueuePtr[?!bool],
) =
  let verified = circom.verify(proof, inputs)

  if (let sent = results.send(verified); sent.isErr()):
    error "Error sending verification results", msg = sent.error().msg

proc verify*[H](
    self: AsyncCircomCompat, proof: CircomProof, inputs: ProofInputs[H]
): Future[?!bool] {.async.} =
  ## Verify a proof using a ctx
  ## 
  without queue =? newSignalQueue[?!bool](maxItems = 1), err:
    return failure(err)

  proc spawnTask() =
    self.tp.spawn verifyTask(self.circom, proof, inputs, queue)

  spawnTask()

  let taskRes = await queue.recvAsync()
  if (let res = queue.release(); res.isErr):
    error "Error releasing proof queue ", msg = res.error().msg
  without verifyRes =? taskRes, err:
    return failure(err)
  without verified =? verifyRes, err:
    return failure(err)

  success(verified)

proc init*(_: type AsyncCircomCompat, params: CircomCompatParams, tp: Taskpool): AsyncCircomCompat =
  ## Create a new async circom
  ##
  let circom = CircomCompat.init(params)
  AsyncCircomCompat(circom: circom, tp: tp)
