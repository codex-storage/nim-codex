## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/sugar
import std/macros
import std/importutils

import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

import pkg/libp2p/[cid, multicodec, multihash]
import pkg/stew/io2

import ./backend
import ../errors
import ../logutils

#nim-taskpool imports

import
  system/ansi_c,
  std/[random, cpuinfo, atomics, macros],
  pkg/taskpools/channels_spsc_single,
  pkg/taskpools/chase_lev_deques,
  pkg/taskpools/event_notifiers,
  pkg/taskpools/primitives/[barriers, allocs],
  pkg/taskpools/instrumentation/[contracts, loggers],
  pkg/taskpools/sparsesets,
  pkg/taskpools/flowvars,
  pkg/taskpools/ast_utils

when (NimMajor,NimMinor,NimPatch) >= (1,6,0):
  import std/[isolation, tasks]
  export isolation
else:
  import pkg/taskpools/shims_pre_1_6/tasks

privateAccess Task

import
  std/[cpuinfo, atomics, macros]

logScope:
  topics = "codex asyncerasure"

const
  CompletitionTimeout = 1.seconds # Maximum await time for completition after receiving a signal
  CompletitionRetryDelay = 10.millis

type
  EncoderBackendPtr = ptr EncoderBackend
  DecoderBackendPtr = ptr DecoderBackend

  # Args objects are missing seq[seq[byte]] field, to avoid unnecessary data copy
  EncodeTaskArgs = object
    signal: ThreadSignalPtr
    backend: EncoderBackendPtr
    blockSize: int
    ecM: int

  DecodeTaskArgs = object
    signal: ThreadSignalPtr
    backend: DecoderBackendPtr
    blockSize: int
    ecK: int

  SharedArrayHolder*[T] = object
    data: ptr UncheckedArray[T]
    size: int

  EncodeTaskResult = Result[SharedArrayHolder[byte], cstring]
  DecodeTaskResult = Result[SharedArrayHolder[byte], cstring]

proc dumpOf(prefix: string, bytes: seq[seq[byte]]): void = 
  for i in 0..<bytes.len:
    # if bytes[i].isNil:
    #   echo "bytes " & $i $ " is nil"
    if bytes[i].len > 0:
      io2.writeFile(prefix & $i, bytes[i]).tryGet()

template tempHashOf(bytes: untyped): untyped =
  echo "len is " & $len(bytes)
  var totalLen = 0
  for i in 0..<len(bytes):
    totalLen = totalLen + bytes[i].len

  var buf = newSeq[byte]()

  buf.setLen(totalLen)

  var offset = 0
  for i in 0..<len(bytes):
    if bytes[i].len > 0:
      echo "pointer " & $i & " " & (unsafeAddr bytes[i][0]).repr
      copyMem(addr buf[offset], unsafeAddr bytes[i][0], bytes[i].len)
      offset = offset + bytes[i].len

  let mhash = MultiHash.digest("sha2-256", buf)
  mhash.get().hex


proc hashOf(bytes: seq[seq[byte]]): string =
  var totalLen = 0
  for i in 0..<len(bytes):
    totalLen = totalLen + bytes[i].len

  var buf = newSeq[byte]()

  buf.setLen(totalLen)

  var offset = 0
  for i in 0..<len(bytes):
    if bytes[i].len > 0:
      copyMem(addr buf[offset], unsafeAddr bytes[i][0], bytes[i].len)
      offset = offset + bytes[i].len

  let mhash = MultiHash.digest("sha2-256", buf)
  return mhash.get().hex


proc hashOfRef(bytes: ref seq[seq[byte]]): string =
  var totalLen = 0
  for i in 0..<len(bytes[]):
    totalLen = totalLen + bytes[i].len

  var buf = newSeq[byte]()

  buf.setLen(totalLen)

  var offset = 0
  for i in 0..<len(bytes[]):
    if bytes[i].len > 0:
      copyMem(addr buf[offset], addr bytes[i][0], bytes[i].len)
      offset = offset + bytes[i].len

  let mhash = MultiHash.digest("sha2-256", buf)
  return mhash.get().hex

proc unsafeHashOf(bytes: seq[pointer], lens: seq[int]): string =
  var totalLen = 0
  for l in lens:
    totalLen = totalLen + l

  var buf = newSeq[byte]()

  buf.setLen(totalLen)

  var offset = 0
  for i in 0..<lens.len:
    let l = lens[i]
    if l > 0:
      echo "pointer " & $i & " " & bytes[i].repr
      copyMem(addr buf[offset], bytes[i], l)
      offset = offset + l

  let mhash = MultiHash.digest("sha2-256", buf)
  return mhash.get().hex

proc encodeTask(args: EncodeTaskArgs, data: seq[seq[byte]]): EncodeTaskResult =
  var
    data = data.unsafeAddr
    parity = newSeqWith[seq[byte]](args.ecM, newSeq[byte](args.blockSize))

  try:
    let res = args.backend[].encode(data[], parity)

    if res.isOk:
      let
        resDataSize = parity.len * args.blockSize
        resData = cast[ptr UncheckedArray[byte]](allocShared0(resDataSize))
        arrHolder = SharedArrayHolder[byte](
          data: resData,
          size: resDataSize
        )

      for i in 0..<parity.len:
        copyMem(addr resData[i * args.blockSize], addr parity[i][0], args.blockSize)

      return ok(arrHolder)
    else:
      return err(res.error)
  except CatchableError as exception:
    return err(exception.msg.cstring)
  finally:
    if err =? args.signal.fireSync().mapFailure.errorOption():
      error "Error firing signal", msg = err.msg

proc decodeTask(args: DecodeTaskArgs, odata: seq[seq[byte]], oparity: seq[seq[byte]], debug: bool): DecodeTaskResult =

  echo "starting task code"

  if debug:
    dumpOf("thread_data_", odata)
    dumpOf("thread_parity", oparity)
  # if debugFlag:
    # io2.writeFile("original_block_" & $idx, blk.data).tryGet()

  var ptrsData: seq[pointer]
  for i in 0..<odata.len:
    if odata[i].len > 0:
      ptrsData.add(unsafeAddr odata[i][0])
    else:
      ptrsData.add(unsafeAddr odata)

  var ptrsParity: seq[pointer]
  for i in 0..<oparity.len:
    if (unsafeAddr oparity[i]).isNil:
      # echo "oparity is Nil " & $i
      ptrsParity.add(unsafeAddr oparity)
    else:
      if oparity[i].len > 0:
        ptrsParity.add(unsafeAddr oparity[i][0])
      else:
        ptrsParity.add(unsafeAddr oparity)

  echo "bef unsafe hash of data " & unsafeHashOf(ptrsData, odata.mapIt(it.len))
  echo "bef unsafe hash of parity " & unsafeHashOf(ptrsParity, oparity.mapIt(it.len))

  var
    data = odata.unsafeAddr
    parity = oparity.unsafeAddr

  var
    recovered = newSeqWith[seq[byte]](args.ecK, newSeq[byte](args.blockSize))

  var ptrs: seq[pointer]
  for i in 0..<recovered.len:
    ptrs.add(unsafeAddr recovered[i][0])

  try:
    let res = args.backend[].decode(data[], parity[], recovered)

    if res.isOk:
      let
        resDataSize = recovered.len * args.blockSize
        resData = cast[ptr UncheckedArray[byte]](allocShared0(resDataSize))
        arrHolder = SharedArrayHolder[byte](
          data: resData,
          size: resDataSize
        )

      for i in 0..<recovered.len:
        copyMem(addr resData[i * args.blockSize], addr recovered[i][0], args.blockSize)

      return ok(arrHolder)
    else:
      return err(res.error)
  except CatchableError as exception:
    return err(exception.msg.cstring)
  finally:
    if err =? args.signal.fireSync().mapFailure.errorOption():
      error "Error firing signal", msg = err.msg

proc proxySpawnEncodeTask(
  tp: Taskpool,
  args: EncodeTaskArgs,
  data: ref seq[seq[byte]]
): Flowvar[EncodeTaskResult] =
  tp.spawn encodeTask(args, data[])

proc proxySpawnDecodeTask(
  tp: Taskpool,
  args: DecodeTaskArgs,
  data: ref seq[seq[byte]],
  parity: ref seq[seq[byte]]
): Flowvar[DecodeTaskResult] =
  # let h = hashOfRef(data)
  # echo "proxy hash of data " & h

  let h1 = tempHashOf(data[])
  echo "proxy hash of data " & h1

  let ph1 = tempHashOf(parity[])
  echo "proxy hash of parity " & ph1

  let debug = h1 == "12208A6C662044230A1760A4E1EE77D5D6A4C9176BA8E04F15C532FBB3D06D42F0D3"


  let fut = newFlowVar(typeof(DecodeTaskResult))
  proc taskpool_decodeTask(args: DecodeTaskArgs; odata: seq[seq[byte]];
                           oparity: seq[seq[byte]]; debug: bool;
                           fut: Flowvar[DecodeTaskResult]) {.nimcall.} =
    let resgensym115 = decodeTask(args, odata, oparity, debug)
    readyWith(fut, resgensym115)

  type
    ScratchObj_11005855178 = object
      args: DecodeTaskArgs
      odata: seq[seq[byte]]
      oparity: seq[seq[byte]]
      debug: bool
      fut: Flowvar[EncodeTaskResult]

  let scratch_11005855162 = cast[ptr ScratchObj_11005855178](c_calloc(
      csize_t(1), csize_t(64)))
  if isNil(scratch_11005855162):
    raise
      (ref OutOfMemDefect)(msg: "Could not allocate memory", parent: nil)
  block:
    var isoTemp_11005855168 = isolate(args)
    scratch_11005855162.args = extract(isoTemp_11005855168)
    var isoTemp_11005855170: Isolated[seq[seq[byte]]] = isolate(data[])

    let h2 = tempHashOf(isoTemp_11005855170.value)
    echo "proxy hash of isolated data " & h2

    scratch_11005855162.odata = extract(isoTemp_11005855170)

    let h3 = tempHashOf(scratch_11005855162.odata)
    echo "proxy hash of moved data " & h3

    
    
    var isoTemp_11005855172 = isolate(parity[])

    let ph2 = tempHashOf(isoTemp_11005855172.value)
    echo "proxy hash of isolated parity " & ph2

    scratch_11005855162.oparity = extract(isoTemp_11005855172)

    GC_fullCollect()

    # let ph3 = tempHashOf(scratch_11005855162.oparity)
    # echo "proxy hash of moved parity " & ph3

    # let h22 = tempHashOf(isoTemp_11005855170.value)
    # echo "proxy hash of isolated data 2 " & h22

    # let h32 = tempHashOf(scratch_11005855162.odata)
    # echo "proxy hash of moved data 2 " & h32

    var isoTemp_11005855174 = isolate(debug)
    scratch_11005855162.debug = extract(isoTemp_11005855174)
    var isoTemp_11005855176 = isolate(fut)
    scratch_11005855162.fut = extract(isoTemp_11005855176)
  proc taskpool_decodeTask_11005855179(argsgensym120: pointer) {.gcsafe,
      nimcall.} =
    let objTemp_11005855167 = cast[ptr ScratchObj_11005855178](argsgensym120)
    let args_11005855169 = objTemp_11005855167.args
    let odata_11005855171 = objTemp_11005855167.odata
    let oparity_11005855173 = objTemp_11005855167.oparity
    let debug_11005855175 = objTemp_11005855167.debug
    let fut_11005855177 = objTemp_11005855167.fut
    taskpool_decodeTask(args_11005855169, odata_11005855171, oparity_11005855173,
                        debug_11005855175, fut_11005855177)

  proc destroyScratch_11005855180(argsgensym120: pointer) {.gcsafe, nimcall.} =
    let obj_11005855181 = cast[ptr ScratchObj_11005855178](argsgensym120)
    `=destroy`(obj_11005855181[])

  let task = Task(callback: taskpool_decodeTask_11005855179, args: scratch_11005855162,
        destroy: destroyScratch_11005855180)
  
  let taskNode = new(TaskNode, taskpools.workerContext.currentTask, task)
  schedule(taskpools.workerContext, taskNode)
  fut

  # expandMacros:
  #   tp.spawn decodeTask(args, data[], parity[], debug)

  # tp.spawn decodeTask(args, data[], parity[], debug)
  # let res = DecodeTaskResult.newFlowVar

  # res.readyWith(decodeTask(args, data[], parity[], debug))
  # return res
  

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

proc asyncEncode*(
  tp: Taskpool,
  backend: EncoderBackend,
  data: ref seq[seq[byte]],
  blockSize: int,
  ecM: int
): Future[?!ref seq[seq[byte]]] {.async.} =
  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  try:
    let
      blockSize = data[0].len
      args = EncodeTaskArgs(signal: signal, backend: unsafeAddr backend, blockSize: blockSize, ecM: ecM)
      handle = proxySpawnEncodeTask(tp, args, data)

    without res =? await awaitResult(signal, handle), err:
      return failure(err)

    if res.isOk:
      var parity = seq[seq[byte]].new()
      parity[].setLen(ecM)

      for i in 0..<parity[].len:
        parity[i] = newSeq[byte](blockSize)
        copyMem(addr parity[i][0], addr res.value.data[i * blockSize], blockSize)

      deallocShared(res.value.data)

      return success(parity)
    else:
      return failure($res.error)
  finally:
    if err =? signal.close().mapFailure.errorOption():
      error "Error closing signal", msg = $err.msg

proc asyncDecode*(
  tp: Taskpool,
  backend: DecoderBackend,
  data, parity: ref seq[seq[byte]],
  blockSize: int
): Future[?!ref seq[seq[byte]]] {.async.} =
  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  echo "orig hash of data " & hashOfRef(data)
  # echo "hash of parity " & hashOfRef(parity)

  try:
    let
      ecK = data[].len
      args = DecodeTaskArgs(signal: signal, backend: unsafeAddr backend, blockSize: blockSize, ecK: ecK)
      handle = proxySpawnDecodeTask(tp, args, data, parity)

    # GC_fullCollect()

    without res =? await awaitResult(signal, handle), err:
      return failure(err)

    if res.isOk:
      var recovered = seq[seq[byte]].new()
      recovered[].setLen(ecK)

      for i in 0..<recovered[].len:
        recovered[i] = newSeq[byte](blockSize)
        copyMem(addr recovered[i][0], addr res.value.data[i * blockSize], blockSize)

      # echo "orig hash of recovered " & hashOfRef(recovered)

      var ptrs: seq[pointer]

      for i in 0..<recovered[].len:
        ptrs.add(unsafeAddr recovered[i][0])


      # echo "unsafe hash of recovered" & unsafeHashOf(ptrs, recovered[].mapIt(it.len))

      # echo "orig hash of parity " & hashOfRef(parity)

      deallocShared(res.value.data)

      return success(recovered)
    else:
      return failure($res.error)
  finally:
    if err =? signal.close().mapFailure.errorOption():
      error "Error closing signal", msg = $err.msg

proc syncDecode*(
  tp: Taskpool,
  backend: DecoderBackend,
  data, parity: ref seq[seq[byte]],
  blockSize: int
): Future[?!ref seq[seq[byte]]] {.async.} =

  let
    ecK = data[].len
  
  var recovered = newSeqWith[seq[byte]](ecK, newSeq[byte](blockSize))

  backend.decode(data[], parity[], recovered)

  var recoveredRet = seq[seq[byte]].new()
  recoveredRet[].setLen(ecK)

  for i in 0..<recoveredRet[].len:
    recoveredRet[i] = newSeq[byte](blockSize)
    copyMem(addr recoveredRet[i][0], addr recovered[i][0], blockSize)

  return success(recoveredRet)


  # without signal =? ThreadSignalPtr.new().mapFailure, err:
  #   return failure(err)

  # try:
  #   let
  #     ecK = data[].len
  #     args = DecodeTaskArgs(signal: signal, backend: unsafeAddr backend, blockSize: blockSize, ecK: ecK)
  #     handle = proxySpawnDecodeTask(tp, args, data, parity)

  #   without res =? await awaitResult(signal, handle), err:
  #     return failure(err)

  #   if res.isOk:
  #     var recovered = seq[seq[byte]].new()
  #     recovered[].setLen(ecK)

  #     for i in 0..<recovered[].len:
  #       recovered[i] = newSeq[byte](blockSize)
  #       copyMem(addr recovered[i][0], addr res.value.data[i * blockSize], blockSize)

  #     deallocShared(res.value.data)

  #     return success(recovered)
  #   else:
  #     return failure($res.error)
  # finally:
  #   if err =? signal.close().mapFailure.errorOption():
  #     error "Error closing signal", msg = $err.msg
