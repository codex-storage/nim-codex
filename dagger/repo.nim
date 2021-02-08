import std/options
import std/tables
import std/hashes
import pkg/chronos
import pkg/libp2p
import ./obj
import ./repo/waitinglist

export options
export obj

type
  Repo* = ref object
    storage: Table[Cid, Object]
    waiting: WaitingList[Cid]

proc hash(id: Cid): Hash =
  hash($id)

proc store*(repo: Repo, obj: Object) =
  let id = obj.cid
  repo.storage[id] = obj
  repo.waiting.deliver(id)

proc contains*(repo: Repo, id: Cid): bool =
  repo.storage.hasKey(id)

proc retrieve*(repo: Repo, id: Cid): Option[Object] =
  if repo.contains(id):
    repo.storage[id].some
  else:
    Object.none

proc wait*(repo: Repo, id: Cid, timeout: Duration): Future[void] =
  var future: Future[void]
  if repo.contains(id):
    future = newFuture[void]()
    future.complete()
  else:
    future = repo.waiting.wait(id, timeout)
  future
