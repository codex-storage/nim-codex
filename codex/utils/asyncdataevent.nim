import pkg/questionable
import pkg/questionable/results
import pkg/chronos

type
  AsyncDataEventSubscription* = ref object
    key: EventQueueKey
    isRunning: bool
    fireEvent: AsyncEvent
    stopEvent: AsyncEvent
    lastResult: ?!void

  AsyncDataEvent*[T] = ref object
    queue: AsyncEventQueue[?T]
    subscriptions: seq[AsyncDataEventSubscription]

  AsyncDataEventHandler*[T] = proc(data: T): Future[?!void]

proc newAsyncDataEvent*[T](): AsyncDataEvent[T] =
  AsyncDataEvent[T](
    queue: newAsyncEventQueue[?T](),
    subscriptions: newSeq[AsyncDataEventSubscription]()
  )

proc subscribe*[T](event: AsyncDataEvent[T], handler: AsyncDataEventHandler[T]): AsyncDataEventSubscription =
  let subscription = AsyncDataEventSubscription(
    key: event.queue.register(),
    isRunning: true,
    fireEvent: newAsyncEvent(),
    stopEvent: newAsyncEvent()
  )

  proc listener() {.async.} =
    while subscription.isRunning:
      let items = await event.queue.waitEvents(subscription.key)
      for item in items:
        if data =? item:
          subscription.lastResult = (await handler(data))
      subscription.fireEvent.fire()
    subscription.stopEvent.fire()

  asyncSpawn listener()

  event.subscriptions.add(subscription)
  subscription

proc fire*[T](event: AsyncDataEvent[T], data: T): Future[?!void] {.async.} =
  event.queue.emit(data.some)
  for subscription in event.subscriptions:
    await subscription.fireEvent.wait()
    if err =? subscription.lastResult.errorOption:
      return failure(err)
  success()

proc unsubscribe*[T](event: AsyncDataEvent[T], subscription: AsyncDataEventSubscription) {.async.} =
  subscription.isRunning = false
  event.queue.emit(T.none)
  await subscription.stopEvent.wait()
  event.subscriptions.delete(event.subscriptions.find(subscription))

proc unsubscribeAll*[T](event: AsyncDataEvent[T]) {.async.} =
  let all = event.subscriptions
  for subscription in all:
    await event.unsubscribe(subscription)
