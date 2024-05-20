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
  params*: CircomCompatParams
  tp*: Taskpool

var circomBackend {.threadvar.}: Option[CircomCompat]

proc proveTask[H](
    params: CircomCompatParams,
    data: ProofInputs[H],
    results: SignalQueuePtr[Result[CircomProof, string]],
) =
  var val: Result[CircomProof, string]

  let proof = circomBackend.get().prove(data)
  if proof.isOk():
    val.ok(proof.get())
  else:
    val.err(proof.error().msg)

  if (let sent = results.send(val); sent.isErr()):
    error "Error sending proof results", msg = sent.error().msg

proc prove*[H](
    self: AsyncCircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =
  ## Generates proof using circom-compat asynchronously
  ##

  without queue =? newSignalQueue[Result[CircomProof, string]](), err:
    return failure(err)

  proc spawnTask() =
    self.tp.spawn proveTask(self.params, input, queue)

  spawnTask()

  without taskRes =? await queue.recvAsync(), err:
    return failure(err)

  if (let res = queue.release(); res.isErr):
    return failure "Error releasing proof queue " & res.error().msg

  without proof =? taskRes.mapFailure, err:
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
