## This file defines the Logos Storage context and its thread flow:
## 1. Client enqueues a request and signals the Logos Storage thread.
## 2. The Logos Storage thread dequeues the request and sends an ack (reqReceivedSignal).
## 3. The Logos Storage thread executes the request asynchronously.
## 4. On completion, the Logos Storage thread invokes the client callback with the result and userData.

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, locks, atomics]
import chronicles
import chronos
import chronos/threadsync
import taskpools/channels_spsc_single
import ./ffi_types
import ./storage_thread_requests/[storage_thread_request]

from ../codex/codex import CodexServer

logScope:
  topics = "libstorage"

type StorageContext* = object
  thread: Thread[(ptr StorageContext)]

  # This lock is only necessary while we use a SP Channel and while the signalling
  # between threads assumes that there aren't concurrent requests.
  # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
  # requests concurrently and spare us the need of locks
  lock: Lock

  # Channel to send requests to the Logos Storage thread.
  # Requests will be popped from this channel.
  reqChannel: ChannelSPSCSingle[ptr StorageThreadRequest]

  # To notify the Logos Storage thread that a request is ready
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

  # Set to false to stop the Logos Storage thread (during storage_destroy)
  running: Atomic[bool]

template callEventCallback(ctx: ptr StorageContext, eventName: string, body: untyped) =
  ## Template used to notify the client of global events 
  ## Example: onConnectionChanged, onProofMissing, etc. 
  if isNil(ctx[].eventCallback):
    error eventName&" - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[StorageCallback](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[StorageCallback](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

proc sendRequestToStorageThread*(
    ctx: ptr StorageContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: StorageCallback,
    userData: pointer,
    timeout = InfiniteDuration,
): Result[void, string] =
  ctx.lock.acquire()

  defer:
    ctx.lock.release()

  let req = StorageThreadRequest.createShared(reqType, reqContent, callback, userData)

  # Send the request to the Logos Storage thread
  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    deallocShared(req)
    return err("Failed to send request to the Logos Storage thread: " & $req[])

  # Notify the Logos Storage thread that a request is available
  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    deallocShared(req)
    return err(
      "Failed to send request to the Logos Storage thread: unable to fireSync: " &
        $fireSyncRes.error
    )

  if fireSyncRes.get() == false:
    deallocShared(req)
    return
      err("Failed to send request to the Logos Storage thread: fireSync timed out.")

  # Wait until the Logos Storage thread properly received the request
  let res = ctx.reqReceivedSignal.waitSync(timeout)
  if res.isErr():
    deallocShared(req)
    return err(
      "Failed to send request to the Logos Storage thread: unable to receive reqReceivedSignal signal."
    )

  ## Notice that in case of "ok", the deallocShared(req) is performed by the Logos Storage thread in the
  ## process proc. See the 'storage_thread_request.nim' module for more details.
  ok()

proc runStorage(ctx: ptr StorageContext) {.async: (raises: []).} =
  var storage: CodexServer

  while true:
    try:
      # Wait until a request is available
      await ctx.reqSignal.wait()
    except Exception as e:
      error "Failure in run Logos Storage thread while waiting for reqSignal.",
        error = e.msg
      continue

    # If storage_destroy was called, exit the loop
    if ctx.running.load == false:
      break

    var request: ptr StorageThreadRequest

    # Pop a request from the channel
    let recvOk = ctx.reqChannel.tryRecv(request)
    if not recvOk:
      error "Failure in run Storage: unable to receive request in Logos Storage thread."
      continue

    # yield immediately to the event loop
    # with asyncSpawn only, the code will be executed
    # synchronously until the first await
    asyncSpawn (
      proc() {.async.} =
        await sleepAsync(0)
        await StorageThreadRequest.process(request, addr storage)
    )()

    # Notify the main thread that we picked up the request
    let fireRes = ctx.reqReceivedSignal.fireSync()
    if fireRes.isErr():
      error "Failure in run Storage: unable to fire back to requester thread.",
        error = fireRes.error

proc run(ctx: ptr StorageContext) {.thread.} =
  waitFor runStorage(ctx)

proc createStorageContext*(): Result[ptr StorageContext, string] =
  ## This proc is called from the main thread and it creates
  ## the Logos Storage working thread.

  # Allocates a StorageContext in shared memory  (for the main thread)
  var ctx = createShared(StorageContext, 1)

  # This signal is used by the main side to wake the Logos Storage thread 
  # when a new request is enqueued.
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return
      err("Failed to create a context: unable to create reqSignal ThreadSignalPtr.")

  # Used to let the caller know that the Logos Storage thread has 
  # acknowledged / picked up a request (like a handshake).
  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err(
      "Failed to create Logos Storage context: unable to create reqReceivedSignal ThreadSignalPtr."
    )

  # Protects shared state inside StorageContext
  ctx.lock.initLock()

  # Logos Storage thread will loop until storage_destroy is called
  ctx.running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err(
      "Failed to create Logos Storage context: unable to create thread: " &
        getCurrentExceptionMsg()
    )

  return ok(ctx)

proc destroyStorageContext*(ctx: ptr StorageContext): Result[void, string] =
  # Signal the Logos Storage thread to stop
  ctx.running.store(false)

  # Wake the worker up if it's waiting
  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("Failed to destroy Logos Storage context: " & $error)

  if not signaledOnTime:
    return err(
      "Failed to destroy Logos Storage context: unable to get signal reqSignal on time in destroyStorageContext."
    )

  # Wait for the thread to finish
  joinThread(ctx.thread)

  # Clean up
  ctx.lock.deinitLock()
  ?ctx.reqSignal.close()
  ?ctx.reqReceivedSignal.close()
  freeShared(ctx)

  return ok()
