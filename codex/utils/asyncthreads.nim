
import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

const
  CompletionRetryDelay* = 10.millis
  CompletionTimeout* = 1.seconds # Maximum await time for completition after receiving a signal

proc awaitThreadResult*[T](signal: ThreadSignalPtr, handle: Flowvar[T]): Future[?!T] {.async.} =
  await wait(signal)

  template closeSig() =
    let sigRes = signal.close()
    if sigRes.isErr:
      return failure(sigRes.error())

  var
    res: T
    awaitTotal: Duration

  while awaitTotal < CompletionTimeout:
    if handle.tryComplete(res): ## TODO: pretty sure this leaks currently
      closeSig()
      return success(res)
    else:
      awaitTotal += CompletionRetryDelay
      await sleepAsync(CompletionRetryDelay)

  closeSig()
  return failure("Task signaled finish but didn't return any result within " & $CompletionRetryDelay)
