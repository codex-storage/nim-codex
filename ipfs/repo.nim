import std/tables
import std/hashes
import pkg/libp2p
import ./merkledag

export merkledag

type
  Repo* = ref object
    storage: Table[Cid, MerkleDag]

proc hash(id: Cid): Hash =
  hash($id)

proc store*(repo: Repo, dag: MerkleDag) =
  repo.storage[dag.rootId] = dag

proc contains*(repo: Repo, id: Cid): bool =
  repo.storage.hasKey(id)

proc retrieve*(repo: Repo, id: Cid): MerkleDag =
  repo.storage[id]
