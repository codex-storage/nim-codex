import std/options
from pkg/libp2p import `==`
import pkg/chronos
import pkg/stint
import pkg/ethers/erc20
import pkg/codex/contracts
import pkg/codex/utils/stintutils
import ../contracts/time
import ../contracts/deployment
import ./twonodes


# For debugging you can enable logging output with debugX = true
# You can also pass a string in same format like for the `--log-level` parameter
# to enable custom logging levels for specific topics like: debug2 = "INFO; TRACE: marketplace"

twonodessuite "Integration tests", debug1 = false, debug2 = false:

  proc purchaseStateIs(client: CodexClient, id: PurchaseId, state: string): bool =
    client.getPurchase(id).option.?state == some state

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
    let cid1 = client1.upload("some file contents").get
    let cid2 = client1.upload("some other contents").get
    check cid1 != cid2

  test "node handles new storage availability":
    let availability1 = client1.postAvailability(size=1.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    let availability2 = client1.postAvailability(size=4.u256, duration=5.u256, minPrice=6.u256, maxCollateral=7.u256).get
    check availability1 != availability2

  test "node lists storage that is for sale":
    let availability = client1.postAvailability(size=1.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    check availability in client1.getAvailabilities().get

  test "node handles storage request":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents").get
    let id1 = client1.requestStorage(cid, duration=1.u256, reward=2.u256, proofProbability=3.u256, expiry=expiry, collateral=200.u256).get
    let id2 = client1.requestStorage(cid, duration=4.u256, reward=5.u256, proofProbability=6.u256, expiry=expiry, collateral=201.u256).get
    check id1 != id2

  test "node retrieves purchase status":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents").get
    let id = client1.requestStorage(cid, duration=1.u256, reward=2.u256, proofProbability=3.u256, expiry=expiry, collateral=200.u256, nodes=2, tolerance=1).get
    let request = client1.getPurchase(id).get.request.get
    check request.ask.duration == 1.u256
    check request.ask.reward == 2.u256
    check request.ask.proofProbability == 3.u256
    check request.expiry == expiry
    check request.ask.collateral == 200.u256
    check request.ask.slots == 3'u64
    check request.ask.maxSlotLoss == 1'u64

  test "node remembers purchase status after restart":
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents").get
    let id = client1.requestStorage(cid,
                                    duration=1.u256,
                                    reward=2.u256,
                                    proofProbability=3.u256,
                                    expiry=expiry,
                                    collateral=200.u256).get
    check eventually client1.purchaseStateIs(id, "submitted")

    node1.restart()
    client1.restart()

    check eventually client1.purchaseStateIs(id, "submitted")
    let request = client1.getPurchase(id).get.request.get
    check request.ask.duration == 1.u256
    check request.ask.reward == 2.u256
    check request.ask.proofProbability == 3.u256
    check request.expiry == expiry
    check request.ask.collateral == 200.u256
    check request.ask.slots == 1'u64
    check request.ask.maxSlotLoss == 0'u64


  test "nodes negotiate contracts on the marketplace":
    let size = 0xFFFFF.u256
    # client 2 makes storage available
    discard client2.postAvailability(size=size, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256)

    # client 1 requests storage
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents").get
    let id = client1.requestStorage(cid, duration=100.u256, reward=400.u256, proofProbability=3.u256, expiry=expiry, collateral=200.u256).get

    check eventually client1.purchaseStateIs(id, "started")
    let purchase = client1.getPurchase(id).get
    check purchase.error == none string
    let availabilities = client2.getAvailabilities().get
    check availabilities.len == 1
    let newSize = availabilities[0].size
    check newSize > 0 and newSize < size

  test "node slots gets paid out":
    let marketplace = Marketplace.new(Marketplace.address, provider.getSigner())
    let tokenAddress = await marketplace.token()
    let token = Erc20Token.new(tokenAddress, provider.getSigner())
    let reward = 400.u256
    let duration = 100.u256

    # client 2 makes storage available
    let startBalance = await token.balanceOf(account2)
    discard client2.postAvailability(size=0xFFFFF.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get

    # client 1 requests storage
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents").get
    let id = client1.requestStorage(cid, duration=duration, reward=reward, proofProbability=3.u256, expiry=expiry, collateral=200.u256).get

    check eventually client1.purchaseStateIs(id, "started")
    let purchase = client1.getPurchase(id).get
    check purchase.error == none string

    # Proving mechanism uses blockchain clock to do proving/collect/cleanup round
    # hence we must use `advanceTime` over `sleepAsync` as Hardhat does mine new blocks
    # only with new transaction
    await provider.advanceTime(duration)

    check eventually (await token.balanceOf(account2)) - startBalance == duration*reward
