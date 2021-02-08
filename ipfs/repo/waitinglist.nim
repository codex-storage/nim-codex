import std/tables
import std/sequtils
import std/sugar
import pkg/chronos

type WaitingList*[T] = ref object
  futures: Table[T, seq[Future[void]]]

proc remove[T](list: WaitingList[T], item: T, future: Future[void]) =
  list.futures[item].keepIf(x => x != future)
  if list.futures[item].len == 0:
    list.futures.del(item)

proc wait*[T](list: WaitingList[T], item: T, timeout: Duration): Future[void] =
  let future = newFuture[void]("waitinglist.wait")
  proc onTimeout(_: pointer) =
    if not future.finished:
      future.complete()
      list.remove(item, future)
  discard setTimer(Moment.fromNow(timeout), onTimeout, nil)
  list.futures.mgetOrPut(item, @[]).add(future)
  future

proc deliver*[T](list: WaitingList[T], item: T) =
  if list.futures.hasKey(item):
    for future in list.futures[item]:
      future.complete()
    list.futures.del(item)

proc count*[T](list: WaitingList[T]): int =
  for x in list.futures.values:
    result += x.len
