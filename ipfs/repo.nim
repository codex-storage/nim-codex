import std/options
import std/tables
import std/hashes
import pkg/libp2p
import ./ipfsobject

export options
export ipfsobject

type
  Repo* = ref object
    storage: Table[Cid, IpfsObject]

proc hash(id: Cid): Hash =
  hash($id)

proc store*(repo: Repo, obj: IpfsObject) =
  repo.storage[obj.cid] = obj

proc contains*(repo: Repo, id: Cid): bool =
  repo.storage.hasKey(id)

proc retrieve*(repo: Repo, id: Cid): Option[IpfsObject] =
  if repo.contains(id):
    repo.storage[id].some
  else:
    IpfsObject.none
