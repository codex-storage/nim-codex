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

proc newAsyncDataEvent*[T]: AsyncDataEvent[T] =
  echo "new event"
  AsyncDataEvent[T](
    queue: newAsyncEventQueue[?T](),
    subscriptions: newSeq[AsyncDataEventSubscription]()
  )

proc subscribeA*[T](event: AsyncDataEvent[T], handler: AsyncDataEventHandler[T]): AsyncDataEventSubscription =
  echo "subscribing..."
  let subscription = AsyncDataEventSubscription(
    key: event.queue.register(),
    isRunning: true,
    fireEvent: newAsyncEvent(),
    stopEvent: newAsyncEvent()
  )

  proc listener() {.async.} =
    echo " >>> listener starting!"
    while subscription.isRunning:
      echo " >>> waiting for event"
      let items = await event.queue.waitEvents(subscription.key)
      for item in items:
        if data =? item:
          echo " >>> got data"
          subscription.lastResult = (await handler(data))
      subscription.fireEvent.fire()
    echo " >>> stopping..."
    subscription.stopEvent.fire()

  asyncSpawn listener()

  event.subscriptions.add(subscription)
  echo "subscribed"
  subscription

proc fireA*[T](event: AsyncDataEvent[T], data: T): Future[?!void] {.async.} =
  echo "firing..."
  event.queue.emit(data.some)
  echo "checking results:"
  for subscription in event.subscriptions:
    await subscription.fireEvent.wait()
    if err =? subscription.lastResult.errorOption:
      return failure(err)
  echo "ok, fired"
  success()

proc unsubscribeA*[T](event: AsyncDataEvent[T], subscription: AsyncDataEventSubscription) {.async.} =
  echo "unsubscribing..."
  subscription.isRunning = false
  event.queue.emit(T.none)
  echo "waiting for stop event"
  await subscription.stopEvent.wait()
  echo "all done"

