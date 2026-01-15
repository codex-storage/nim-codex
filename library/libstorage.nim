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

import std/[atomics]
import chronicles
import chronos
import chronos/threadsync
import ./storage_context
import ./storage_thread_requests/storage_thread_request
import ./storage_thread_requests/requests/node_lifecycle_request
import ./storage_thread_requests/requests/node_info_request
import ./storage_thread_requests/requests/node_debug_request
import ./storage_thread_requests/requests/node_p2p_request
import ./storage_thread_requests/requests/node_upload_request
import ./storage_thread_requests/requests/node_download_request
import ./storage_thread_requests/requests/node_storage_request
import ./ffi_types

from ../codex/conf import codexVersion

logScope:
  topics = "libstorage"

template checkLibstorageParams*(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
) =
  if not isNil(ctx):
    ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

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

proc storage_version(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  callback(
    RET_OK,
    cast[ptr cchar](conf.codexVersion),
    cast[csize_t](len(conf.codexVersion)),
    userData,
  )

  return RET_OK

proc storage_revision(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  callback(
    RET_OK,
    cast[ptr cchar](conf.codexRevision),
    cast[csize_t](len(conf.codexRevision)),
    userData,
  )

  return RET_OK

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

proc storage_close(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent = NodeLifecycleRequest.createShared(NodeLifecycleMsgType.CLOSE_NODE)
  var res = storage_context.sendRequestToStorageThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  )
  if res.isErr:
    return callback.error(res.error, userData)

  return callback.okOrError(res, userData)

proc storage_destroy(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let res = storage_context.destroyStorageContext(ctx)
  if res.isErr:
    return RET_ERR

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

proc storage_stop(
    ctx: ptr StorageContext, callback: StorageCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibstorageParams(ctx, callback, userData)

  let reqContent: ptr NodeLifecycleRequest =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.STOP_NODE)
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
