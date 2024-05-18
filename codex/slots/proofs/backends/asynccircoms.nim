import std/options

import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

import ../../types
import ../../../utils/asyncthreads

import ./circomcompat

type
  AsyncCircomCompat* = object
    params*: CircomCompatParams
    tp*: Taskpool

  # Args objects are missing seq[seq[byte]] field, to avoid unnecessary data copy
  ProveTaskArgs* = object
    signal: ThreadSignalPtr
    params: CircomCompatParams

var circomBackend {.threadvar.}: Option[CircomCompat]

proc proveTask[H](
    args: ProveTaskArgs, data: ProofInputs[H]
): Result[CircomProof, string] =

  try:
    if circomBackend.isNone:
      circomBackend = some CircomCompat.init(args.params)
    else:
      assert circomBackend.get().params == args.params

    let res = circomBackend.get().prove(data)
    if res.isOk:
      return ok(res.get())
    else:
      return err(res.error().msg)
  except CatchableError as exception:
    return err(exception.msg)
  finally:
    if err =? args.signal.fireSync().mapFailure.errorOption():
      error "Error firing signal in proveTask ", msg = err.msg

proc prove*[H](
    self: AsyncCircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =
  ## Generates proof using circom-compat asynchronously
  ##

  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)
  defer:
    let sigRes = signal.close()
    if sigRes.isErr:
      raise (ref Defect)(msg: sigRes.error())

  let args = ProveTaskArgs(signal: signal, params: self.params)
  proc spawnTask(): Flowvar[Result[CircomProof, string]] =
    self.tp.spawn proveTask(args, input)
  let flowvar = spawnTask()

  without taskRes =? await awaitThreadResult(signal, flowvar),  err:
    return failure(err)

  without proof =? taskRes.mapFailure, err:
    let res: ?!CircomProof = failure(err)
    return res

  let pf: CircomProof = proof
  success(pf)


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
