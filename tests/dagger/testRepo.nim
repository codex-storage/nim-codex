import pkg/asynctest
import pkg/chronos
import pkg/dagger/repo

suite "repo":

  let obj = Object(data: @[1'u8, 2'u8, 3'u8])
  var repo: Repo

  setup:
    repo = Repo()

  test "stores objects":
    repo.store(obj)

  test "retrieves objects by their content id":
    repo.store(obj)
    check repo.retrieve(obj.cid).get() == obj

  test "signals retrieval failure":
    check repo.retrieve(obj.cid).isNone

  test "knows which content ids are stored":
    check repo.contains(obj.cid) == false
    repo.store(obj)
    check repo.contains(obj.cid) == true

  test "waits for object to arrive":
    let waiting = repo.wait(obj.cid, 1.minutes)
    check not waiting.finished
    repo.store(obj)
    check waiting.finished

  test "does not wait when object is already stored":
    repo.store(obj)
    check repo.wait(obj.cid, 1.minutes).finished
