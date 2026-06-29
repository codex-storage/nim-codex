# libstorage.nim - C-exported interface for the Storage shared library
#
# This file implements the public C API for libstorage.
# It acts as the bridge between C programs and the internal Nim implementation.
#
# This file defines:
# - Initialization logic for the Nim runtime (once per process)
# - Thread-safe exported procs callable from C
# - Callback registration and invocation for asynchronous communication

# cdecl is C declaration calling convention.
# It’s the standard way C compilers expect functions to behave:
# 1- Caller cleans up the stack after the call
# 2- Symbol names are exported in a predictable way
# In other termes, it is a glue that makes Nim functions callable as normal C functions.
{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}

# Ensure code is position-independent so it can be built into a shared library (.so).
# In other terms, the code that can run no matter where it’s placed in memory.
{.passc: "-fPIC".}

when defined(linux):
  # Define the canonical name for this library
  {.passl: "-Wl,-soname,libstorage.so".}

import std/[atomics, exitprocs, locks]
import chronicles
import chronos
import chronos/threadsync
import results
import taskpools/channels_spsc_single
import ./storage_context
import ./storage_thread_requests/storage_thread_request
import ./storage_thread_requests/requests/node_lifecycle_request
import ./storage_thread_requests/requests/node_info_request
import ./storage_thread_requests/requests/node_debug_request
import ./storage_thread_requests/requests/node_p2p_request
import ./storage_thread_requests/requests/node_upload_request
import ./storage_thread_requests/requests/node_download_request
import ./storage_thread_requests/requests/node_storage_request
import ./storage_thread_requests/requests/node_mix_request
import ./ffi_types

from ../storage/conf import storageVersion

logScope:
  topics = "libstorage"

type ShutdownContext = object
  ctx: ptr StorageContext
  callback: StorageCallback
  userData: pointer
  doneSignal: ThreadSignalPtr
  ret: cint
  msg: ptr cchar
  len: csize_t

type ShutdownSupervisor = object
  thread: Thread[void]
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr ShutdownContext]
  reqSignal: ThreadSignalPtr
  running: Atomic[bool]

var
  shutdownSupervisor: ShutdownSupervisor
  shutdownSupervisorReady: Atomic[bool]

template checkLibstorageParams*(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
) =
  if not isNil(ctx):
    ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}

proc asNewCString(s: string): ptr cchar =
  # We need malloc so C clients can free it.
  let
    n = s.len
    cstr = cast[ptr UncheckedArray[cchar]](malloc(n.csize_t + 1))
  if n > 0:
    copyMem(cstr, addr s[0], n)
  cstr[n] = 0.cchar
  cast[ptr cchar](cstr)

proc copySharedMsg(msg: ptr cchar, len: csize_t): ptr cchar =
  if isNil(msg) or len == 0:
    return nil

  let size = len + 1
  let copied = cast[ptr cchar](allocShared(size))
  let bytes = cast[ptr UncheckedArray[cchar]](copied)
  copyMem(copied, msg, len)
  bytes[len] = '\0'
  return copied

proc setShutdownResult(
    sctx: ptr ShutdownContext, ret: cint, msg: ptr cchar, len: csize_t
) =
  if not isNil(sctx[].msg):
    deallocShared(sctx[].msg)
    sctx[].msg = nil

  sctx[].ret = ret
  sctx[].msg = copySharedMsg(msg, len)
  sctx[].len = len

proc setShutdownError(sctx: ptr ShutdownContext, msg: string) =
  if msg.len == 0:
    setShutdownResult(sctx, RET_ERR, nil, 0)
    return

  setShutdownResult(sctx, RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len))

proc shutdownStorageCallback(
    ret: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.callback.} =
  let sctx = cast[ptr ShutdownContext](userData)
  if isNil(sctx):
    return

  setShutdownResult(sctx, ret, msg, len)
  discard sctx[].doneSignal.fireSync()

proc runShutdown(sctx: ptr ShutdownContext) =
  if isNil(sctx):
    return

  let reqContent: ptr NodeLifecycleRequest =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.SHUTDOWN_NODE)
  let dispatchRes = storage_context.sendRequestToStorageThread(
    sctx[].ctx,
    RequestType.LIFECYCLE,
    reqContent,
    shutdownStorageCallback,
    cast[pointer](sctx),
  )

  if dispatchRes.isOk:
    let waitRes = sctx[].doneSignal.waitSync(InfiniteDuration)
    if waitRes.isErr:
      setShutdownError(
        sctx,
        "Failed to shutdown Logos Storage context: unable to receive shutdown result.",
      )
  else:
    setShutdownError(sctx, dispatchRes.error)

  let destroyRes = storage_context.destroyStorageContext(sctx[].ctx)
  if destroyRes.isErr and sctx[].ret == RET_OK:
    setShutdownError(sctx, destroyRes.error)

  foreignThreadGc:
    sctx[].callback(sctx[].ret, sctx[].msg, sctx[].len, sctx[].userData)

  if not isNil(sctx[].msg):
    deallocShared(sctx[].msg)
  discard sctx[].doneSignal.close()
  deallocShared(sctx)

proc runShutdownSupervisor() {.thread.} =
  while true:
    let waitRes = shutdownSupervisor.reqSignal.waitSync(InfiniteDuration)
    if waitRes.isErr:
      error "Failure in Logos Storage shutdown supervisor while waiting for reqSignal.",
        error = waitRes.error
      continue

    var sctx: ptr ShutdownContext
    var recvOk = false
    shutdownSupervisor.lock.acquire()
    try:
      recvOk = shutdownSupervisor.reqChannel.tryRecv(sctx)
    finally:
      shutdownSupervisor.lock.release()

    if recvOk:
      runShutdown(sctx)

    if shutdownSupervisor.running.load == false:
      break

proc stopShutdownSupervisor() {.noconv.} =
  if not shutdownSupervisorReady.exchange(false):
    return

  shutdownSupervisor.running.store(false)
  discard shutdownSupervisor.reqSignal.fireSync()
  joinThread(shutdownSupervisor.thread)

  shutdownSupervisor.lock.deinitLock()
  discard shutdownSupervisor.reqSignal.close()

proc startShutdownSupervisor(): Result[void, string] =
  shutdownSupervisor.reqSignal = ThreadSignalPtr.new().valueOr:
    return err(
      "Failed to initialize Logos Storage shutdown supervisor: unable to create reqSignal."
    )

  shutdownSupervisor.lock.initLock()
  shutdownSupervisor.running.store(true)

  try:
    createThread(shutdownSupervisor.thread, runShutdownSupervisor)
  except ValueError, ResourceExhaustedError:
    shutdownSupervisor.lock.deinitLock()
    discard shutdownSupervisor.reqSignal.close()
    return err(
      "Failed to initialize Logos Storage shutdown supervisor: unable to create thread: " &
        getCurrentExceptionMsg()
    )

  shutdownSupervisorReady.store(true)
  addExitProc(stopShutdownSupervisor)
  return ok()

# From Nim doc:
# "the C targets require you to initialize Nim's internals, which is done calling a NimMain function."
# "The name NimMain can be influenced via the --nimMainPrefix:prefix switch."
# "Use --nimMainPrefix:MyLib and the function to call is named MyLibNimMain."
proc libstorageNimMain() {.importc.}

# Atomic flag to prevent multiple initializations
var initialized: Atomic[bool]

if defined(android):
  # Redirect chronicles to Android System logs
  when compiles(defaultChroniclesStream.outputs[0].writer):
    defaultChroniclesStream.outputs[0].writer = proc(
        logLevel: LogLevel, msg: LogOutputStr
    ) {.raises: [].} =
      echo logLevel, msg

# Initializes the Nim runtime and foreign-thread GC
proc initializeLibrary() {.exported.} =
  if not initialized.exchange(true):
    ## Every Nim library must call `<prefix>NimMain()` once
    libstorageNimMain()
    startShutdownSupervisor().isOkOr:
      error "Failed to initialize Logos Storage shutdown supervisor.", error = error
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

proc storage_new(
    configJson: cstring, callback: StorageCallback, userData: pointer
): pointer {.dynlib, exported.} =
  initializeLibrary()

  if isNil(callback):
    error "Failed to create Storage instance: the callback is missing."
    return nil

  if not shutdownSupervisorReady.load:
    let msg = "Failed to create Storage instance: shutdown supervisor is not initialized."
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  var ctx = storage_context.createStorageContext().valueOr:
    let msg = $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

  let reqContent =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.CREATE_NODE, configJson)

  storage_context.sendRequestToStorageThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  ).isOkOr:
    let msg = $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  return ctx

proc storage_version(ctx: ptr StorageContext): ptr cchar {.dynlib, exportc.} =
  initializeLibrary()

  return asNewCString(conf.storageVersion)

proc storage_revision(ctx: ptr StorageContext): ptr cchar {.dynlib, exportc.} =
  initializeLibrary()

  return asNewCString(conf.storageVersion)

proc storage_repo(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent = NodeInfoRequest.createShared(NodeInfoMsgType.REPO)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.INFO, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_debug(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent = NodeDebugRequest.createShared(NodeDebugMsgType.DEBUG)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.DEBUG, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_spr(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent = NodeInfoRequest.createShared(NodeInfoMsgType.SPR)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.INFO, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_peer_id(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent = NodeInfoRequest.createShared(NodeInfoMsgType.PEERID)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.INFO, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_get_metrics(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent = NodeInfoRequest.createShared(NodeInfoMsgType.METRICS)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.INFO, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

## Set the log level of the library at runtime.
## It uses updateLogLevel which is a synchronous proc and
## cannot be used inside an async context because of gcsafe issue.
proc storage_log_level(
    ctx: ptr StorageContext,
    logLevel: cstring,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent =
    NodeDebugRequest.createShared(NodeDebugMsgType.LOG_LEVEL, logLevel = logLevel)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.DEBUG, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_connect(
    ctx: ptr StorageContext,
    peerId: cstring,
    peerAddressesPtr: ptr cstring,
    peerAddressesLength: csize_t,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  var peerAddresses = newSeq[cstring](peerAddressesLength)
  let peers = cast[ptr UncheckedArray[cstring]](peerAddressesPtr)
  for i in 0 ..< peerAddressesLength:
    peerAddresses[i] = peers[i]

  let reqContent = NodeP2PRequest.createShared(
    NodeP2PMsgType.CONNECT, peerId = peerId, peerAddresses = peerAddresses
  )
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.P2P, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_peer_debug(
    ctx: ptr StorageContext,
    peerId: cstring,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent = NodeDebugRequest.createShared(NodeDebugMsgType.PEER, peerId = peerId)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.DEBUG, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_shutdown(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()

  if isNil(callback):
    return RET_MISSING_CALLBACK

  if isNil(ctx):
    return callback.error("Storage context not initialized.", userData)

  let doneSignal = ThreadSignalPtr.new().valueOr:
    return callback.error(
      "Failed to shutdown Logos Storage context: unable to create done signal.",
      userData,
    )

  let sctx = createShared(ShutdownContext, 1)
  sctx[].ctx = ctx
  sctx[].callback = callback
  sctx[].userData = userData
  sctx[].doneSignal = doneSignal
  sctx[].ret = RET_ERR

  if not shutdownSupervisorReady.load:
    discard doneSignal.close()
    deallocShared(sctx)
    return callback.error(
      "Failed to shutdown Logos Storage context: shutdown supervisor is not initialized.",
      userData,
    )

  shutdownSupervisor.lock.acquire()
  let sentOk = shutdownSupervisor.reqChannel.trySend(sctx)
  shutdownSupervisor.lock.release()

  if not sentOk:
    discard doneSignal.close()
    deallocShared(sctx)
    return callback.error(
      "Failed to shutdown Logos Storage context: shutdown supervisor is busy.",
      userData,
    )

  let fireRes = shutdownSupervisor.reqSignal.fireSync()
  if fireRes.isErr or fireRes.get() == false:
    var queuedCtx: ptr ShutdownContext
    var recvOk = false
    shutdownSupervisor.lock.acquire()
    try:
      recvOk = shutdownSupervisor.reqChannel.tryRecv(queuedCtx)
    finally:
      shutdownSupervisor.lock.release()

    if recvOk and queuedCtx == sctx:
      discard doneSignal.close()
      deallocShared(sctx)
      return callback.error(
        "Failed to shutdown Logos Storage context: unable to signal shutdown supervisor.",
        userData,
      )

    warn "Failed to signal Logos Storage shutdown supervisor after shutdown request was accepted."
    return RET_OK

  return RET_OK

proc storage_upload_init(
    ctx: ptr StorageContext,
    filepath: cstring,
    chunkSize: csize_t,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent = NodeUploadRequest.createShared(
    NodeUploadMsgType.INIT, filepath = filepath, chunkSize = chunkSize
  )

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_upload_chunk(
    ctx: ptr StorageContext,
    sessionId: cstring,
    data: ptr byte,
    len: csize_t,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let chunk = newSeq[byte](len)
  copyMem(addr chunk[0], data, len)

  let reqContent = NodeUploadRequest.createShared(
    NodeUploadMsgType.CHUNK, sessionId = sessionId, chunk = chunk
  )
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_upload_finalize(
    ctx: ptr StorageContext,
    sessionId: cstring,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent =
    NodeUploadRequest.createShared(NodeUploadMsgType.FINALIZE, sessionId = sessionId)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_upload_cancel(
    ctx: ptr StorageContext,
    sessionId: cstring,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent =
    NodeUploadRequest.createShared(NodeUploadMsgType.CANCEL, sessionId = sessionId)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_upload_file(
    ctx: ptr StorageContext,
    sessionId: cstring,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent =
    NodeUploadRequest.createShared(NodeUploadMsgType.FILE, sessionId = sessionId)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_toggle_private_queries(
    ctx: ptr StorageContext, enabled: bool, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeMixRequest.createShared(privateQueries = enabled)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.MIX, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_download_init(
    ctx: ptr StorageContext,
    cid: cstring,
    chunkSize: csize_t,
    local: bool,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeDownloadRequest.createShared(
    NodeDownloadMsgType.INIT, cid = cid, chunkSize = chunkSize, local = local
  )

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.DOWNLOAD, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_download_chunk(
    ctx: ptr StorageContext, cid: cstring, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeDownloadRequest.createShared(NodeDownloadMsgType.CHUNK, cid = cid)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.DOWNLOAD, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_download_stream(
    ctx: ptr StorageContext,
    cid: cstring,
    chunkSize: csize_t,
    local: bool,
    filepath: cstring,
    callback: StorageCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeDownloadRequest.createShared(
    NodeDownloadMsgType.STREAM,
    cid = cid,
    chunkSize = chunkSize,
    local = local,
    filepath = filepath,
  )

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.DOWNLOAD, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_download_cancel(
    ctx: ptr StorageContext, cid: cstring, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeDownloadRequest.createShared(NodeDownloadMsgType.CANCEL, cid = cid)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.DOWNLOAD, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_download_manifest(
    ctx: ptr StorageContext, cid: cstring, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeDownloadRequest.createShared(NodeDownloadMsgType.MANIFEST, cid = cid)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.DOWNLOAD, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_list(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeStorageRequest.createShared(NodeStorageMsgType.LIST)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.STORAGE, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_space(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeStorageRequest.createShared(NodeStorageMsgType.SPACE)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.STORAGE, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_delete(
    ctx: ptr StorageContext, cid: cstring, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeStorageRequest.createShared(NodeStorageMsgType.DELETE, cid = cid)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.STORAGE, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_fetch(
    ctx: ptr StorageContext, cid: cstring, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeStorageRequest.createShared(NodeStorageMsgType.FETCH, cid = cid)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.STORAGE, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_exists(
    ctx: ptr StorageContext, cid: cstring, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let req = NodeStorageRequest.createShared(NodeStorageMsgType.EXISTS, cid = cid)

  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.STORAGE, req, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_start(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent: ptr NodeLifecycleRequest =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.START_NODE)
  let res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc storage_set_event_callback(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
) {.dynlib, exportc.} =
  initializeLibrary()
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData
