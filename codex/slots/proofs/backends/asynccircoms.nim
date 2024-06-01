import std/options
import std/hashes

import pkg/taskpools
import pkg/chronicles
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

import ../../types
import ../../../utils/asyncthreads
import ../../../merkletree

import ./circomcompat

logScope:
  topics = "codex asyncprover"

type
  AsyncCircomCompat* = object
    params*: CircomCompatParams
    circom*: CircomCompat
    tp*: Taskpool

  AsyncCircomTask* = object
    params*: CircomCompatParams
    data*: ProofInputs[Poseidon2Hash]

var localCircom {.threadvar.}: Option[CircomCompat]

proc proveTask(
    # params: CircomCompatParams, data: ProofInputs[Poseidon2Hash], results: SignalQueuePtr[?!CircomProof]
    args: ptr AsyncCircomTask,
    results: SignalQueuePtr[?!CircomProof]
) =

  var data = args[].data
  var params = args[].params
  try:
    echo "TASK: task: "
    echo "TASK: task: params: ", params.r1csPath.cstring.pointer.repr
    echo "TASK: task: params: ", params
    echo "TASK: task: ", data.hash
    if localCircom.isNone:
      localCircom = some CircomCompat.init(params)
    # echo "TASK: task: ", data
    let proof = localCircom.get().prove(data)

    GC_fullCollect()
    # echo "TASK: task: proof: ", proof.get.hash
    echo "TASK: task: proof: ", proof
    echo "TASK: task: params POST: ", params
    # let fake = CircomProof.failure("failed")
    if (let sent = results.send(proof); sent.isErr()):
      error "Error sending proof results", msg = sent.error().msg
  except Exception:
    echo "PROVER DIED"
  except Defect:
    echo "PROVER DIED"
  except:
    echo "PROVER DIED"

proc spawnProveTask(
    tp: TaskPool,
    # params: CircomCompatParams, input: ProofInputs[Poseidon2Hash],
    args: ptr AsyncCircomTask,
    results: SignalQueuePtr[?!CircomProof]
) =
  tp.spawn proveTask(args, results)

proc prove*[H](
    self: AsyncCircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =
  ## Generates proof using circom-compat asynchronously
  ##
  without queue =? newSignalQueue[?!CircomProof](maxItems = 1), qerr:
    return failure(qerr)

  echo "TASK: task spawn: params: ", self.params.r1csPath.cstring.pointer.repr
  var args = (ref AsyncCircomTask)(params: self.params, data: input)
  GC_ref(args)
  self.tp.spawnProveTask(args[].addr, queue)

  let taskRes = await queue.recvAsync()

  if (let res = queue.release(); res.isErr):
    error "Error releasing proof queue ", msg = res.error().msg
  without proofRes =? taskRes, perr:
    return failure(perr)
  without proof =? proofRes, perr:
    return failure(perr)

  GC_unref(args)
  success(proof)

proc verifyTask[H](
    params: CircomCompatParams,
    proof: CircomProof,
    inputs: ProofInputs[H],
    results: SignalQueuePtr[?!bool],
) =
  echo "VERIFY: task: proof: ", proof

  var params = params
  if localCircom.isNone:
    localCircom = some CircomCompat.init(params)

  let verified = localCircom.get().verify(proof, inputs)

  echo "VERIFY: task: result: ", verified
  if (let sent = results.send(verified); sent.isErr()):
    error "Error sending verification results", msg = sent.error().msg

proc verify*[H](
    self: AsyncCircomCompat, proof: CircomProof, inputs: ProofInputs[H]
): Future[?!bool] {.async.} =
  ## Verify a proof using a ctx
  ## 
  without queue =? newSignalQueue[?!bool](maxItems = 1), qerr:
    return failure(qerr)

  proc spawnTask() =
    self.tp.spawn verifyTask(self.params, proof, inputs, queue)

  spawnTask()

  let taskRes = await queue.recvAsync()
  if (let res = queue.release(); res.isErr):
    error "Error releasing proof queue ", msg = res.error().msg
  without verifyRes =? taskRes, verr:
    return failure(verr)
  without verified =? verifyRes, verr:
    return failure(verr)

  success(verified)

proc init*(_: type AsyncCircomCompat, params: CircomCompatParams, tp: Taskpool): AsyncCircomCompat =
  ## Create a new async circom
  ##
  # let circom = CircomCompat.init(params)
  AsyncCircomCompat(params: params, tp: Taskpool.new(2))
