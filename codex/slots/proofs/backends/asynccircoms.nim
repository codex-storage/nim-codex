import std/options

import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

import ../../types
import ../../../utils/asyncthreads

import ./circomcompat

type AsyncCircomCompat* = object
  circom*: CircomCompat
  tp*: Taskpool

proc proveTask[H](
    circom: CircomCompat,
    data: ProofInputs[H],
    results: SignalQueuePtr[?!CircomProof],
) =
  let proof = circom.prove(data)

  if (let sent = results.send(proof); sent.isErr()):
    error "Error sending proof results", msg = sent.error().msg

proc prove*[H](
    self: AsyncCircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =
  ## Generates proof using circom-compat asynchronously
  ##

  without queue =? newSignalQueue[?!CircomProof](), err:
    return failure(err)
  defer:
    if (let res = queue.release(); res.isErr):
      error "Error releasing proof queue ", msg = res.error().msg

  template spawnTask() =
    self.tp.spawn proveTask(self.circom, input, queue)

  spawnTask()

  without taskRes =? await queue.recvAsync(), err:
    return failure(err)

  without proof =? taskRes, err:
    return failure(err)

  success(proof)

proc verify*[H](
    self: AsyncCircomCompat, proof: CircomProof, inputs: ProofInputs[H]
): Future[?!bool] {.async.} =
  ## Verify a proof using a ctx
  ##
  discard

proc init*(_: type AsyncCircomCompat, params: CircomCompatParams): AsyncCircomCompat =
  ## Create a new async circom
  ##
  let circom = CircomCompat.init(params)
  AsyncCircomCompat(circom)
