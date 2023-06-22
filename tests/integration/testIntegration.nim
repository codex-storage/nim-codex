import std/json
import pkg/chronos
import pkg/stint
import pkg/ethers/erc20
import pkg/codex/contracts
import pkg/codex/utils/stintutils
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers/eventually
import ./twonodes

# For debugging you can enable logging output with debugX = true
# You can also pass a string in same format like for the `--log-level` parameter
# to enable custom logging levels for specific topics like: debug2 = "INFO; TRACE: marketplace"

twonodessuite "Integration tests", debug1 = false, debug2 = false:
  setup:
    # Our Hardhat configuration does use automine, which means that time tracked by `provider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests provider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await provider.advanceTime(1.u256)

  test "nodes can print their peer information":
    check client1.info() != client2.info()

  test "nodes can set chronicles log level":
    client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads":
    let cid1 = client1.upload("some file contents")
    let cid2 = client1.upload("some other contents")
    check cid1 != cid2

  test "node handles new storage availability":
    let availability1 = client1.postAvailability(size=1, duration=2, minPrice=3, maxCollateral=4)
    let availability2 = client1.postAvailability(size=4, duration=5, minPrice=6, maxCollateral=7)
    check availability1 != availability2

  test "node lists storage that is for sale":
    let availability = client1.postAvailability(size=1, duration=2, minPrice=3, maxCollateral=4)
    check availability in client1.getAvailabilities()

  test "node handles storage request":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let id1 = client1.requestStorage(cid, duration=1, reward=2, proofProbability=3, expiry=expiry, collateral=200)
    let id2 = client1.requestStorage(cid, duration=4, reward=5, proofProbability=6, expiry=expiry, collateral=201)
    check id1 != id2

  test "node retrieves purchase status":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let id = client1.requestStorage(cid, duration=1, reward=2, proofProbability=3, expiry=expiry, collateral=200)
    let purchase = client1.getPurchase(id)
    check purchase{"request"}{"ask"}{"duration"} == %"1"
    check purchase{"request"}{"ask"}{"reward"} == %"2"
    check purchase{"request"}{"ask"}{"proofProbability"} == %"3"

  test "node remembers purchase status after restart":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let id = client1.requestStorage(cid, duration=1, reward=2, proofProbability=3, expiry=expiry, collateral=200)
    check eventually client1.getPurchase(id){"state"}.getStr() == "submitted"

    node1.restart()
    client1.restart()

    check eventually (not isNil client1.getPurchase(id){"request"}{"ask"})
    check client1.getPurchase(id){"request"}{"ask"}{"duration"} == %"1"
    check client1.getPurchase(id){"request"}{"ask"}{"reward"} == %"2"

  test "nodes negotiate contracts on the marketplace":
    let size: uint64 = 0xFFFFF
    # client 2 makes storage available
    discard client2.postAvailability(size=size, duration=200, minPrice=300, maxCollateral=300)

    # client 1 requests storage
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let purchase = client1.requestStorage(cid, duration=100, reward=400, proofProbability=3, expiry=expiry, collateral=200)

    check eventually client1.getPurchase(purchase){"state"} == %"started"
    check client1.getPurchase(purchase){"error"} == newJNull()
    let availabilities = client2.getAvailabilities()
    check availabilities.len == 1
    let newSize = UInt256.fromDecimal(availabilities[0]{"size"}.getStr)
    check newSize > 0 and newSize < size.u256

  test "node slots gets paid out":
    let marketplace = Marketplace.new(Marketplace.address, provider.getSigner())
    let tokenAddress = await marketplace.token()
    let token = Erc20Token.new(tokenAddress, provider.getSigner())
    let reward: uint64 = 400
    let duration: uint64 = 100

    # client 2 makes storage available
    let startBalance = await token.balanceOf(account2)
    discard client2.postAvailability(size=0xFFFFF, duration=200, minPrice=300, maxCollateral=300)

    # client 1 requests storage
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let purchase = client1.requestStorage(cid, duration=duration, reward=reward, proofProbability=3, expiry=expiry, collateral=200)

    check eventually client1.getPurchase(purchase){"state"} == %"started"
    check client1.getPurchase(purchase){"error"} == newJNull()

    # Proving mechanism uses blockchain clock to do proving/collect/cleanup round
    # hence we must use `advanceTime` over `sleepAsync` as Hardhat does mine new blocks
    # only with new transaction
    await provider.advanceTime(duration.u256)

    check eventually (await token.balanceOf(account2)) - startBalance == duration.u256*reward.u256
