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

type
  AsyncCircomCompat* = object
    circom*: CircomCompat
    tp*: Taskpool

  ProverArgs[H] = object
    circom: CircomCompat
    data: ProofInputs[H]

  VerifierArgs[H] = object
    circom: CircomCompat
    proof: CircomProof
    inputs: ProofInputs[H]

var
  localCircom {.threadvar.}: Option[CircomCompat]

proc proveTask[H](args: ptr ProverArgs[H], results: SignalQueuePtr[?!CircomProof]) =

  if localCircom.isNone:
    localCircom = some args.circom.duplicate()

  var data = args[].data
  let proof = localCircom.get().prove(data)

  echo "PROVE TASK: proof: ", proof

  let verified = localCircom.get().verify(proof.get(), data)
  echo "PROVE TASK: verify: ", verified

  if (let sent = results.send(proof); sent.isErr()):
    error "Error sending proof results", msg = sent.error().msg

proc prove*[H](
    self: AsyncCircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =
  ## Generates proof using circom-compat asynchronously
  ##
  without queue =? newSignalQueue[?!CircomProof](maxItems = 1), qerr:
    return failure(qerr)

  var args = (ref ProverArgs[H])(circom: self.circom, data: input)
  GC_ref(args)

  proc spawnTask() =
    self.tp.spawn proveTask(args[].addr, queue)

  spawnTask()

  let taskRes = await queue.recvAsync()

  GC_unref(args)
  if (let res = queue.release(); res.isErr):
    error "Error releasing proof queue ", msg = res.error().msg
  without proofRes =? taskRes, perr:
    return failure(perr)
  without proof =? proofRes, perr:
    return failure(perr)

  success(proof)

proc verifyTask[H](args: ptr VerifierArgs[H], results: SignalQueuePtr[?!bool]) =

  if localCircom.isNone:
    localCircom = some args.circom.duplicate()

  var proof = args[].proof
  var inputs = args[].inputs
  let verified = localCircom.get().verify(proof, inputs)

  if (let sent = results.send(verified); sent.isErr()):
    error "Error sending verification results", msg = sent.error().msg

proc verify*[H](
    self: AsyncCircomCompat, proof: CircomProof, inputs: ProofInputs[H]
): Future[?!bool] {.async.} =
  ## Verify a proof using a ctx
  ## 
  without queue =? newSignalQueue[?!bool](maxItems = 1), qerr:
    return failure(qerr)

  var args = (ref VerifierArgs[H])(circom: self.circom, proof: proof, inputs: inputs)
  GC_ref(args)

  proc spawnTask() =
    self.tp.spawn verifyTask(args[].addr, queue)

  spawnTask()

  let taskRes = await queue.recvAsync()

  GC_unref(args)
  if (let res = queue.release(); res.isErr):
    error "Error releasing proof queue ", msg = res.error().msg
  without verifyRes =? taskRes, verr:
    return failure(verr)
  without verified =? verifyRes, verr:
    return failure(verr)

  success(verified)

proc init*(
    _: type AsyncCircomCompat, params: CircomCompatParams, tp: Taskpool
): AsyncCircomCompat =
  ## Create a new async circom
  ##
  let circom = CircomCompat.init(params)
  AsyncCircomCompat(circom: circom, tp: tp)

proc duplicate*(
    self: AsyncCircomCompat
): AsyncCircomCompat =
  ## Create a new async circom
  ##
  let circom = self.circom.duplicate()
  AsyncCircomCompat(circom: circom, tp: self.tp)
