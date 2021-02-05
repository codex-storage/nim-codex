## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

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
