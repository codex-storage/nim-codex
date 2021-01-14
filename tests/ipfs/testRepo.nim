import std/unittest
import pkg/ipfs/repo

suite "repo":

  let dag = MerkleDag(data: @[1'u8, 2'u8, 3'u8])
  var repo: Repo

  setup:
    repo = Repo()

  test "stores Merkle DAGs":
    repo.store(dag)

  test "retrieves Merkle DAGs by their root id":
    repo.store(dag)
    check repo.retrieve(dag.rootId) == dag

  test "knows which ids are stored":
    check repo.contains(dag.rootId) == false
    repo.store(dag)
    check repo.contains(dag.rootId) == true
