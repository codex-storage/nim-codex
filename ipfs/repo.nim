import std/options
import std/tables
import std/hashes
import pkg/chronos
import pkg/libp2p
import ./ipfsobject
import ./repo/waitinglist

export options
export ipfsobject

type
  Repo* = ref object
    storage: Table[Cid, IpfsObject]
    waiting: WaitingList[Cid]

proc new*(_: type Repo): Repo =
  Repo(waiting: WaitingList[Cid]())

proc hash(id: Cid): Hash =
  hash($id)

proc store*(repo: Repo, obj: IpfsObject) =
  let id = obj.cid
  repo.storage[id] = obj
  repo.waiting.deliver(id)

proc contains*(repo: Repo, id: Cid): bool =
  repo.storage.hasKey(id)

proc retrieve*(repo: Repo, id: Cid): Option[IpfsObject] =
  if repo.contains(id):
    repo.storage[id].some
  else:
    IpfsObject.none

proc wait*(repo: Repo, id: Cid, timeout: Duration): Future[void] =
  var future: Future[void]
  if repo.contains(id):
    future = newFuture[void]()
    future.complete()
  else:
    future = repo.waiting.wait(id, timeout)
  future
