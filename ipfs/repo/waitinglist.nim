import std/tables
import pkg/chronos

type WaitingList*[T] = object
  futures: Table[T, seq[Future[void]]]

proc wait*[T](list: var WaitingList, item: T, timeout: Duration): Future[void] =
  let future = newFuture[void]("waitinglist.wait")
  proc onTimeout(_: pointer) =
    if not future.finished:
      future.complete()
  discard setTimer(Moment.fromNow(timeout), onTimeout, nil)
  list.futures.mgetOrPut(item, @[]).add(future)
  future

proc deliver*[T](list: var WaitingList, item: T) =
  if list.futures.hasKey(item):
    for future in list.futures[item]:
      future.complete()
    list.futures.del(item)
