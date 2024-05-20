import std/options
import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

const
  CompletionRetryDelay* = 10.millis
  CompletionTimeout* = 1.seconds
    # Maximum await time for completition after receiving a signal

type
  SignalQueue[T] = object
    signal: ThreadSignalPtr
    chan*: Channel[T]

  SignalQueuePtr*[T] = ptr SignalQueue[T]

proc release*[T](queue: SignalQueuePtr[T]): ?!void =
  ## Call to properly dispose of a SignalQueue.
  queue[].chan.close()
  if err =? queue[].signal.close().mapFailure.errorOption():
    queue[].signal = nil
    deallocShared(queue)
    return failure(err.msg)
  else:
    deallocShared(queue)
    return success()

proc newSignalQueue*[T](maxItems: int = 0): ?!SignalQueuePtr[T] =
  ## Create a signal queue compatible with Chronos async.
  result = success cast[ptr SignalQueue[T]](allocShared0(sizeof(SignalQueue[T])))
  without signal =? ThreadSignalPtr.new().mapFailure, sigErr:
    return failure(sigErr)
  result[].signal = signal
  result[].chan.open(maxItems)

proc send*[T](queue: SignalQueuePtr[T], msg: T): ?!void {.raises: [].} =
  ## Sends a message from a regular thread. `msg` is deep copied. May block
  try:
    queue[].chan.send(msg)
  except Exception as exc:
    return failure(exc.msg)

  without wasSent =? queue[].signal.fireSync(InfiniteDuration).mapFailure, sigErr:
    return failure(sigErr)
  if wasSent:
    return ok()
  else:
    return failure("ThreadSignalPtr not signalled in time")

proc recvAsync*[T](queue: SignalQueuePtr[T]): Future[?!T] {.async.} =
  ## Async compatible receive from queue. Pauses async execution until
  ## an item is received from the queue
  await wait(queue.signal)
  let res = queue.chan.tryRecv()
  if not res.dataAvailable:
    return failure("unable to retrieve expected queue value")
  else:
    return success(res.msg)
