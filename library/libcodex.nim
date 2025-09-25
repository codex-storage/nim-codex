# libcodex.nim - C-exported interface for the Codex shared library
#
# This file implements the public C API for libcodex.
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
  {.passl: "-Wl,-soname,libcodex.so".}

import std/[atomics]
import chronicles
import chronos
import ./codex_context
import ./codex_thread_requests/codex_thread_request
import ./codex_thread_requests/requests/node_lifecycle_request
import ./codex_thread_requests/requests/node_info_request
import ./codex_thread_requests/requests/node_debug_request
import ./codex_thread_requests/requests/node_p2p_request
import ./codex_thread_requests/requests/node_upload_request
import ./ffi_types

from ../codex/conf import codexVersion, updateLogLevel

logScope:
  topics = "codexlib"

template checkLibcodexParams*(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
) =
  if not isNil(ctx):
    ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

# From Nim doc: 
# "the C targets require you to initialize Nim's internals, which is done calling a NimMain function."
# "The name NimMain can be influenced via the --nimMainPrefix:prefix switch."
# "Use --nimMainPrefix:MyLib and the function to call is named MyLibNimMain."
proc libcodexNimMain() {.importc.}

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
    libcodexNimMain()
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

proc codex_new(
    configJson: cstring, callback: CodexCallback, userData: pointer
): pointer {.dynlib, exported.} =
  initializeLibrary()

  if isNil(callback):
    error "Missing callback in codex_new"
    return nil

  var ctx = codex_context.createCodexContext().valueOr:
    let msg = "Error in createCodexContext: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

  let reqContent =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.CREATE_NODE, configJson)

  codex_context.sendRequestToCodexThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  ).isOkOr:
    let msg = "libcodex error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  return ctx

proc codex_version(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  callback(
    RET_OK,
    cast[ptr cchar](conf.codexVersion),
    cast[csize_t](len(conf.codexVersion)),
    userData,
  )

  return RET_OK

proc codex_revision(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  callback(
    RET_OK,
    cast[ptr cchar](conf.codexRevision),
    cast[csize_t](len(conf.codexRevision)),
    userData,
  )

  return RET_OK

proc codex_repo(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent = NodeInfoRequest.createShared(NodeInfoMsgType.REPO)
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.INFO, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_debug(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent = NodeDebugRequest.createShared(NodeDebugMsgType.DEBUG)
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.DEBUG, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_spr(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent = NodeInfoRequest.createShared(NodeInfoMsgType.SPR)
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.INFO, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_peer_id(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent = NodeInfoRequest.createShared(NodeInfoMsgType.PEERID)
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.INFO, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

## Set the log level of the library at runtime.
## It uses updateLogLevel which is a synchronous proc and
## cannot be used inside an async context because of gcsafe issue.
proc codex_log_level(
    ctx: ptr CodexContext, logLevel: cstring, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  try:
    updateLogLevel($logLevel)
  except ValueError as e:
    return callback.error(e.msg, userData)

  return callback.success("", userData)

proc codex_connect(
    ctx: ptr CodexContext,
    peerId: cstring,
    peerAddressesPtr: ptr cstring,
    peerAddressesLength: csize_t,
    callback: CodexCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  var peerAddresses = newSeq[cstring](peerAddressesLength)
  let peers = cast[ptr UncheckedArray[cstring]](peerAddressesPtr)
  for i in 0 ..< peerAddressesLength:
    peerAddresses[i] = peers[i]

  let reqContent = NodeP2PRequest.createShared(
    NodeP2PMsgType.CONNECT, peerId = peerId, peerAddresses = peerAddresses
  )
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.P2P, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_peer_debug(
    ctx: ptr CodexContext, peerId: cstring, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent = NodeDebugRequest.createShared(NodeDebugMsgType.PEER, peerId = peerId)
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.DEBUG, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_destroy(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let res = codex_context.destroyCodexContext(ctx)
  if res.isErr:
    return callback.error(res.error, userData)

  return callback.success("", userData)

proc codex_upload_init(
    ctx: ptr CodexContext,
    filepath: cstring,
    chunkSize: csize_t,
    callback: CodexCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent = NodeUploadRequest.createShared(
    NodeUploadMsgType.INIT, filepath = filepath, chunkSize = chunkSize
  )

  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_upload_chunk(
    ctx: ptr CodexContext,
    sessionId: cstring,
    data: ptr byte,
    len: csize_t,
    callback: CodexCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let chunk = newSeq[byte](len)
  copyMem(addr chunk[0], data, len)

  let reqContent = NodeUploadRequest.createShared(
    NodeUploadMsgType.CHUNK, sessionId = sessionId, chunk = chunk
  )
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_upload_finalize(
    ctx: ptr CodexContext,
    sessionId: cstring,
    callback: CodexCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent =
    NodeUploadRequest.createShared(NodeUploadMsgType.FINALIZE, sessionId = sessionId)
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_upload_cancel(
    ctx: ptr CodexContext,
    sessionId: cstring,
    callback: CodexCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent =
    NodeUploadRequest.createShared(NodeUploadMsgType.CANCEL, sessionId = sessionId)

  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_upload_file(
    ctx: ptr CodexContext,
    sessionId: cstring,
    callback: CodexCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let onProgress = proc(
      bytes: int
  ): Future[void] {.async: (raises: [CancelledError]).} =
    if userData != nil:
      callback(RET_PROGRESS, nil, cast[csize_t](bytes), userData)

  let reqContent = NodeUploadRequest.createShared(
    NodeUploadMsgType.FILE, sessionId = sessionId, onProgress = onProgress
  )

  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_upload_subscribe(
    ctx: ptr CodexContext,
    sessionId: cstring,
    callback: CodexCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let onProgress = proc(
      bytes: int
  ): Future[void] {.async: (raises: [CancelledError]).} =
    if userData != nil:
      callback(RET_PROGRESS, nil, cast[csize_t](bytes), userData)

  let reqContent = NodeUploadRequest.createShared(
    NodeUploadMsgType.SUBSCRIBE, sessionId = sessionId, onProgress = onProgress
  )

  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.UPLOAD, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_start(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent: ptr NodeLifecycleRequest =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.START_NODE)
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_stop(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent: ptr NodeLifecycleRequest =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.STOP_NODE)
  let res = codex_context.sendRequestToCodexThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  )

  return callback.okOrError(res, userData)

proc codex_set_event_callback(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
) {.dynlib, exportc.} =
  initializeLibrary()
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData
