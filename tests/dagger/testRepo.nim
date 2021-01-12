import std/unittest
import pkg/dagger/repo

suite "repo":

  let dag = MerkleDag(data: @[1'u8, 2'u8, 3'u8])
  var repo: Repo

  setup:
    repo = Repo()

  test "stores Merkle DAGs":
    repo.store(dag)

  test "retrieves Merkle DAGs by their root hash":
    repo.store(dag)
    check repo.retrieve(dag.rootHash) == dag

  test "knows which hashes are stored":
    check repo.contains(dag.rootHash) == false
    repo.store(dag)
    check repo.contains(dag.rootHash) == true
