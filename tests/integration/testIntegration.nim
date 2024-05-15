import std/options
import std/sequtils
import std/strutils
import std/httpclient
from pkg/libp2p import `==`
import pkg/chronos
import pkg/stint
import pkg/codex/rng
import pkg/stew/byteutils
import pkg/ethers/erc20
import pkg/codex/contracts
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ../codex/examples
import ./twonodes

# For debugging you can enable logging output with debugX = true
# You can also pass a string in same format like for the `--log-level` parameter
# to enable custom logging levels for specific topics like: debug2 = "INFO; TRACE: marketplace"

twonodessuite "Integration tests", debug1 = false, debug2 = false:
  setup:
    # Our Hardhat configuration does use automine, which means that time tracked by `ethProvider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests ethProvider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await ethProvider.advanceTime(1.u256)

  test "nodes negotiate contracts on the marketplace":
    let size = 0xFFFFFF.u256
    let data = await RandomChunker.example(blocks=8)
    # client 2 makes storage available
    let availability = client2.postAvailability(totalSize=size, duration=20*60.u256, minPrice=300.u256, maxCollateral=300.u256).get

    # client 1 requests storage
    let cid = client1.upload(data).get
    let id = client1.requestStorage(
      cid,
      duration=10*60.u256,
      reward=400.u256,
      proofProbability=3.u256,
      expiry=5*60,
      collateral=200.u256,
      nodes = 5,
      tolerance = 2).get

    check eventually(client1.purchaseStateIs(id, "started"), timeout=5*60*1000)
    let purchase = client1.getPurchase(id).get
    check purchase.error == none string
    let availabilities = client2.getAvailabilities().get
    check availabilities.len == 1
    let newSize = availabilities[0].freeSize
    check newSize > 0 and newSize < size

    let reservations = client2.getAvailabilityReservations(availability.id).get
    check reservations.len == 5
    check reservations[0].requestId == purchase.requestId

  test "node slots gets paid out":
    let size = 0xFFFFFF.u256
    let data = await RandomChunker.example(blocks = 8)
    let marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
    let tokenAddress = await marketplace.token()
    let token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
    let reward = 400.u256
    let duration = 10*60.u256
    let nodes = 5'u

    # client 2 makes storage available
    let startBalance = await token.balanceOf(account2)
    discard client2.postAvailability(totalSize=size, duration=20*60.u256, minPrice=300.u256, maxCollateral=300.u256).get

    # client 1 requests storage
    let cid = client1.upload(data).get
    let id = client1.requestStorage(
      cid,
      duration=duration,
      reward=reward,
      proofProbability=3.u256,
      expiry=5*60,
      collateral=200.u256,
      nodes = nodes,
      tolerance = 2).get

    check eventually(client1.purchaseStateIs(id, "started"), timeout=5*60*1000)
    let purchase = client1.getPurchase(id).get
    check purchase.error == none string

    # Proving mechanism uses blockchain clock to do proving/collect/cleanup round
    # hence we must use `advanceTime` over `sleepAsync` as Hardhat does mine new blocks
    # only with new transaction
    await ethProvider.advanceTime(duration)

    check eventually (await token.balanceOf(account2)) - startBalance == duration*reward*nodes.u256
