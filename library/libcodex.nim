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
import ./ffi_types

from ../codex/conf import codexVersion

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

  return RET_ACK

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

  return RET_ACK

proc codex_repo(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent = NodeInfoRequest.createShared(NodeInfoMsgType.REPO)

  codex_context.sendRequestToCodexThread(
    ctx, RequestType.INFO, reqContent, callback, userData
  ).isOkOr:
    let msg = "libcodex error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_ACK

proc codex_destroy(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  codex_context.destroyCodexContext(ctx).isOkOr:
    let msg = "libcodex error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  ## always need to invoke the callback although we don't retrieve value to the caller
  callback(RET_OK, nil, 0, userData)

  return RET_ACK

proc codex_start(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent: ptr NodeLifecycleRequest =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.START_NODE)

  codex_context.sendRequestToCodexThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  ).isOkOr:
    let msg = "libcodex error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_ACK

proc codex_stop(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibcodexParams(ctx, callback, userData)

  let reqContent: ptr NodeLifecycleRequest =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.STOP_NODE)

  codex_context.sendRequestToCodexThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  ).isOkOr:
    let msg = "libcodex error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_ACK

proc codex_set_event_callback(
    ctx: ptr CodexContext, callback: CodexCallback, userData: pointer
) {.dynlib, exportc.} =
  initializeLibrary()
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData
