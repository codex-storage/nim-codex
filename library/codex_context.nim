## This file defines the Codex context and its thread flow:
## 1. Client enqueues a request and signals the Codex thread.
## 2. The Codex thread dequeues the request and sends an ack (reqReceivedSignal).
## 3. The Codex thread executes the request asynchronously.
## 4. On completion, the Codex thread invokes the client callback with the result and userData.

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, locks, atomics]
import chronicles
import chronos
import chronos/threadsync
import taskpools/channels_spsc_single
import ./ffi_types
import ./codex_thread_requests/[codex_thread_request]

from ../codex/codex import CodexServer

logScope:
  topics = "codexlib"

type CodexContext* = object
  thread: Thread[(ptr CodexContext)]

  # This lock is only necessary while we use a SP Channel and while the signalling
  # between threads assumes that there aren't concurrent requests.
  # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
  # requests concurrently and spare us the need of locks
  lock: Lock

  # Channel to send requests to the Codex thread.
  # Requests will be popped from this channel.
  reqChannel: ChannelSPSCSingle[ptr CodexThreadRequest]

  # To notify the Codex thread that a request is ready
  reqSignal: ThreadSignalPtr

  # To notify the client thread that the request was received. 
  # It is acknowledgment signal (handshake).
  reqReceivedSignal: ThreadSignalPtr

  # Custom state attached by the client to a request,
  # returned when its callback is invoked
  userData*: pointer

  # Function called by the library to notify the client of global events
  eventCallback*: pointer

  # Custom state attached by the client to the context, 
  # returned with every event callback
  eventUserData*: pointer

  # Set to false to stop the Codex thread (during codex_destroy)
  running: Atomic[bool]

template callEventCallback(ctx: ptr CodexContext, eventName: string, body: untyped) =
  ## Template used to notify the client of global events 
  ## Example: onConnectionChanged, onProofMissing, etc. 
  if isNil(ctx[].eventCallback):
    error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[CodexCallback](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[CodexCallback](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

proc sendRequestToCodexThread*(
    ctx: ptr CodexContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: CodexCallback,
    userData: pointer,
    timeout = InfiniteDuration,
): Result[void, string] =
  ctx.lock.acquire()

  defer:
    ctx.lock.release()

  let req = CodexThreadRequest.createShared(reqType, reqContent, callback, userData)

  # Send the request to the Codex thread
  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    deallocShared(req)
    return err("Failed to send request to the codex thread: " & $req[])

  # Notify the Codex thread that a request is available
  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    deallocShared(req)
    return err(
      "Failed to send request to the codex thread: unable to fireSync: " &
        $fireSyncRes.error
    )

  if fireSyncRes.get() == false:
    deallocShared(req)
    return err("Failed to send request to the codex thread: fireSync timed out.")

  # Wait until the Codex Thread properly received the request
  let res = ctx.reqReceivedSignal.waitSync(timeout)
  if res.isErr():
    deallocShared(req)
    return err(
      "Failed to send request to the codex thread: unable to receive reqReceivedSignal signal."
    )

  ## Notice that in case of "ok", the deallocShared(req) is performed by the Codex Thread in the
  ## process proc. See the 'codex_thread_request.nim' module for more details.
  ok()

proc runCodex(ctx: ptr CodexContext) {.async: (raises: []).} =
  var codex: CodexServer

  while true:
    try:
      # Wait until a request is available
      await ctx.reqSignal.wait()
    except Exception as e:
      error "Failure in run codex thread while waiting for reqSignal.", error = e.msg
      continue

    # If codex_destroy was called, exit the loop
    if ctx.running.load == false:
      break

    var request: ptr CodexThreadRequest

    # Pop a request from the channel
    let recvOk = ctx.reqChannel.tryRecv(request)
    if not recvOk:
      error "Failure in run codex: unable to receive request in codex thread."
      continue

    # yield immediately to the event loop
    # with asyncSpawn only, the code will be executed
    # synchronously until the first await
    asyncSpawn (
      proc() {.async.} =
        await sleepAsync(0)
        await CodexThreadRequest.process(request, addr codex)
    )()

    # Notify the main thread that we picked up the request
    let fireRes = ctx.reqReceivedSignal.fireSync()
    if fireRes.isErr():
      error "Failure in run codex: unable to fire back to requester thread.",
        error = fireRes.error

proc run(ctx: ptr CodexContext) {.thread.} =
  waitFor runCodex(ctx)

proc createCodexContext*(): Result[ptr CodexContext, string] =
  ## This proc is called from the main thread and it creates
  ## the Codex working thread.

  # Allocates a CodexContext in shared memory  (for the main thread)
  var ctx = createShared(CodexContext, 1)

  # This signal is used by the main side to wake the Codex thread 
  # when a new request is enqueued.
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return
      err("Failed to create a context: unable to create reqSignal ThreadSignalPtr.")

  # Used to let the caller know that the Codex thread has 
  # acknowledged / picked up a request (like a handshake).
  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err(
      "Failed to create codex context: unable to create reqReceivedSignal ThreadSignalPtr."
    )

  # Protects shared state inside CodexContext
  ctx.lock.initLock()

  # Codex thread will loop until codex_destroy is called
  ctx.running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err(
      "Failed to create codex context: unable to create thread: " &
        getCurrentExceptionMsg()
    )

  return ok(ctx)

proc destroyCodexContext*(ctx: ptr CodexContext): Result[void, string] =
  # Signal the Codex thread to stop
  ctx.running.store(false)

  # Wake the worker up if it's waiting
  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("Failed to destroy codex context: " & $error)

  if not signaledOnTime:
    return err(
      "Failed to destroy codex context: unable to get signal reqSignal on time in destroyCodexContext."
    )

  # Wait for the thread to finish
  joinThread(ctx.thread)

  # Clean up
  ctx.lock.deinitLock()
  ?ctx.reqSignal.close()
  ?ctx.reqReceivedSignal.close()
  freeShared(ctx)

  return ok()
