import std/json
import pkg/chronos
import pkg/stint
import ../contracts/time
import ../codex/helpers/eventually
import ./twonodes
import ./tokens

twonodessuite "Integration tests", debug1 = false, debug2 = false:

  setup:
    await provider.getSigner(accounts[0]).mint()
    await provider.getSigner(accounts[1]).mint()
    await provider.getSigner(accounts[1]).deposit()

  test "nodes can print their peer information":
    check client1.info() != client2.info()

  test "nodes can set chronicles log level":
    client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads":
    let cid1 = client1.upload("some file contents")
    let cid2 = client1.upload("some other contents")
    check cid1 != cid2

  test "node handles new storage availability":
    let availability1 = client1.postAvailability(size=1, duration=2, minPrice=3)
    let availability2 = client1.postAvailability(size=4, duration=5, minPrice=6)
    check availability1 != availability2

  test "node lists storage that is for sale":
    let availability = client1.postAvailability(size=1, duration=2, minPrice=3)
    check availability in client1.getAvailabilities()

  test "node handles storage request":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let id1 = client1.requestStorage(cid, duration=1, reward=2, proofProbability=3, expiry=expiry)
    let id2 = client1.requestStorage(cid, duration=4, reward=5, proofProbability=6, expiry=expiry)
    check id1 != id2

  test "node retrieves purchase status":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let id = client1.requestStorage(cid, duration=1, reward=2, proofProbability=3, expiry=expiry)
    let purchase = client1.getPurchase(id)
    check purchase{"request"}{"ask"}{"duration"} == %"0x1"
    check purchase{"request"}{"ask"}{"reward"} == %"0x2"
    check purchase{"request"}{"ask"}{"proofProbability"} == %"0x3"

  test "node remembers purchase status after restart":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let id = client1.requestStorage(cid, duration=1, reward=2, proofProbability=3, expiry=expiry)
    check eventually client1.getPurchase(id){"state"}.getStr() == "submitted"

    node1.restart()
    client1.restart()

    check eventually (not isNil client1.getPurchase(id){"request"}{"ask"})
    check client1.getPurchase(id){"request"}{"ask"}{"duration"} == %"0x1"
    check client1.getPurchase(id){"request"}{"ask"}{"reward"} == %"0x2"

  test "nodes negotiate contracts on the marketplace":
    let size: uint64 = 0xFFFFF
    # client 2 makes storage available
    discard client2.postAvailability(size=size, duration=200, minPrice=300)

    # client 1 requests storage
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let purchase = client1.requestStorage(cid, duration=100, reward=400, proofProbability=3, expiry=expiry)

    check eventually client1.getPurchase(purchase){"state"} == %"started"
    check client1.getPurchase(purchase){"error"} == newJNull()
    let availabilities = client2.getAvailabilities()
    check availabilities.len == 1
    let newSize = UInt256.fromHex(availabilities[0]{"size"}.getStr)
    check newSize > 0 and newSize < size.u256
