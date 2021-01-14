import std/unittest
import pkg/ipfs/repo

suite "repo":

  let obj = IpfsObject(data: @[1'u8, 2'u8, 3'u8])
  var repo: Repo

  setup:
    repo = Repo()

  test "stores IPFS objects":
    repo.store(obj)

  test "retrieves IPFS objects by their content id":
    repo.store(obj)
    check repo.retrieve(obj.cid) == obj

  test "knows which content ids are stored":
    check repo.contains(obj.cid) == false
    repo.store(obj)
    check repo.contains(obj.cid) == true
