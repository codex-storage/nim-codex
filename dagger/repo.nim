import std/tables
import std/hashes
import ./merkledag

export merkledag

type
  Repo* = ref object
    storage: Table[MultiHash, MerkleDag]

proc hash(multihash: MultiHash): Hash =
  hash($multihash)

proc store*(repo: Repo, dag: MerkleDag) =
  repo.storage[dag.rootHash] = dag

proc contains*(repo: Repo, hash: MultiHash): bool =
  repo.storage.hasKey(hash)

proc retrieve*(repo: Repo, hash: MultiHash): MerkleDag =
  repo.storage[hash]
