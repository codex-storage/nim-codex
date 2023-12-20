import std/options
import std/sequtils
import std/httpclient
from pkg/libp2p import `==`
import pkg/chronos
import pkg/stint
import pkg/codex/rng
import pkg/stew/byteutils
import pkg/ethers/erc20
import pkg/codex/contracts
import pkg/codex/utils/stintutils
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./twonodes


# For debugging you can enable logging output with debugX = true
# You can also pass a string in same format like for the `--log-level` parameter
# to enable custom logging levels for specific topics like: debug2 = "INFO; TRACE: marketplace"

twonodessuite "Integration tests", debug1 = false, debug2 = false:

  proc purchaseStateIs(client: CodexClient, id: PurchaseId, state: string): bool =
    without purchase =? client.getPurchase(id):
      return false
    return purchase.state == state

  setup:
    # Our Hardhat configuration does use automine, which means that time tracked by `ethProvider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests ethProvider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await ethProvider.advanceTime(1.u256)

  test "nodes can print their peer information":
    check client1.info() != client2.info()

  test "nodes can set chronicles log level":
    client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads":
    let cid1 = client1.upload("some file contents").get
    let cid2 = client1.upload("some other contents").get
    check cid1 != cid2

  test "node shows used and available space":
    discard client1.upload("some file contents").get
    discard client1.postAvailability(size=12.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    let space = client1.space().tryGet()
    check:
      space.totalBlocks == 2.uint
      space.quotaMaxBytes == 8589934592.uint
      space.quotaUsedBytes == 65518.uint
      space.quotaReservedBytes == 12.uint

  test "node allows local file downloads":
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client2.upload(content2).get

    let resp1 = client1.download(cid1, local = true).get
    let resp2 = client2.download(cid2, local = true).get

    check:
      content1 == resp1
      content2 == resp2

  test "node allows remote file downloads":
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client2.upload(content2).get

    let resp2 = client1.download(cid2, local = false).get
    let resp1 = client2.download(cid1, local = false).get

    check:
      content1 == resp1
      content2 == resp2

  test "node fails retrieving non-existing local file":
    let content1 = "some file contents"
    let cid1 = client1.upload(content1).get # upload to first node
    let resp2 = client2.download(cid1, local = true) # try retrieving from second node

    check:
      resp2.error.msg == "404 Not Found"

  test "node lists local files":
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client1.upload(content2).get
    let list = client1.list().get

    check:
      [cid1, cid2].allIt(it in list.mapIt(it.cid))

  test "node handles new storage availability":
    let availability1 = client1.postAvailability(size=1.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    let availability2 = client1.postAvailability(size=4.u256, duration=5.u256, minPrice=6.u256, maxCollateral=7.u256).get
    check availability1 != availability2

  test "node lists storage that is for sale":
    let availability = client1.postAvailability(size=1.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    check availability in client1.getAvailabilities().get

  test "node handles storage request":
    let expiry = (await ethProvider.currentTime()) + 10
    let cid = client1.upload("some file contents").get
    let id1 = client1.requestStorage(cid, duration=100.u256, reward=2.u256, proofProbability=3.u256, expiry=expiry, collateral=200.u256).get
    let id2 = client1.requestStorage(cid, duration=400.u256, reward=5.u256, proofProbability=6.u256, expiry=expiry, collateral=201.u256).get
    check id1 != id2

  test "node retrieves purchase status":
    # get one contiguous chunk
    let rng = rng.Rng.instance()
    let chunker = RandomChunker.new(rng, size = DefaultBlockSize * 2, chunkSize = DefaultBlockSize * 2)
    let data = await chunker.getBytes()
    let cid = client1.upload(byteutils.toHex(data)).get
    let expiry = (await ethProvider.currentTime()) + 30
    let id = client1.requestStorage(
      cid,
      duration=100.u256,
      reward=2.u256,
      proofProbability=3.u256,
      expiry=expiry,
      collateral=200.u256,
      nodes=2,
      tolerance=1).get

    let request = client1.getPurchase(id).get.request.get
    check request.ask.duration == 100.u256
    check request.ask.reward == 2.u256
    check request.ask.proofProbability == 3.u256
    check request.expiry == expiry
    check request.ask.collateral == 200.u256
    check request.ask.slots == 3'u64
    check request.ask.maxSlotLoss == 1'u64

  # TODO: We currently do not support encoding single chunks
  # test "node retrieves purchase status with 1 chunk":
  #   let expiry = (await ethProvider.currentTime()) + 30
  #   let cid = client1.upload("some file contents").get
  #   let id = client1.requestStorage(cid, duration=1.u256, reward=2.u256, proofProbability=3.u256, expiry=expiry, collateral=200.u256, nodes=2, tolerance=1).get
  #   let request = client1.getPurchase(id).get.request.get
  #   check request.ask.duration == 1.u256
  #   check request.ask.reward == 2.u256
  #   check request.ask.proofProbability == 3.u256
  #   check request.expiry == expiry
  #   check request.ask.collateral == 200.u256
  #   check request.ask.slots == 3'u64
  #   check request.ask.maxSlotLoss == 1'u64

  test "node remembers purchase status after restart":
    let expiry = (await ethProvider.currentTime()) + 30
    let cid = client1.upload("some file contents").get
    let id = client1.requestStorage(cid,
                                    duration=100.u256,
                                    reward=2.u256,
                                    proofProbability=3.u256,
                                    expiry=expiry,
                                    collateral=200.u256).get
    check eventually client1.purchaseStateIs(id, "submitted")

    node1.restart()
    client1.restart()

    check eventually client1.purchaseStateIs(id, "submitted")
    let request = client1.getPurchase(id).get.request.get
    check request.ask.duration == 100.u256
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
    let expiry = (await ethProvider.currentTime()) + 30
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
    let marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
    let tokenAddress = await marketplace.token()
    let token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
    let reward = 400.u256
    let duration = 100.u256

    # client 2 makes storage available
    let startBalance = await token.balanceOf(account2)
    discard client2.postAvailability(size=0xFFFFF.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get

    # client 1 requests storage
    let expiry = (await ethProvider.currentTime()) + 30
    let cid = client1.upload("some file contents").get
    let id = client1.requestStorage(cid, duration=duration, reward=reward, proofProbability=3.u256, expiry=expiry, collateral=200.u256).get

    check eventually client1.purchaseStateIs(id, "started")
    let purchase = client1.getPurchase(id).get
    check purchase.error == none string

    # Proving mechanism uses blockchain clock to do proving/collect/cleanup round
    # hence we must use `advanceTime` over `sleepAsync` as Hardhat does mine new blocks
    # only with new transaction
    await ethProvider.advanceTime(duration)

    check eventually (await token.balanceOf(account2)) - startBalance == duration*reward

  test "node requires expiry and its value to be in future":
    let currentTime = await ethProvider.currentTime()
    let cid = client1.upload("some file contents").get

    let responseMissing = client1.requestStorageRaw(cid, duration=1.u256, reward=2.u256, proofProbability=3.u256, collateral=200.u256)
    check responseMissing.status == "400 Bad Request"
    check responseMissing.body == "Expiry required"

    let responsePast = client1.requestStorageRaw(cid, duration=1.u256, reward=2.u256, proofProbability=3.u256, collateral=200.u256, expiry=currentTime-10)
    check responsePast.status == "400 Bad Request"
    check responsePast.body == "Expiry needs to be in future"

    let responseBefore = client1.requestStorageRaw(cid, duration=1.u256, reward=2.u256, proofProbability=3.u256, collateral=200.u256, expiry=currentTime+10)
    check responseBefore.status == "400 Bad Request"
    check responseBefore.body == "Expiry has to be before the request's end (now + duration)"

  # TODO: skipping this test for now as is not passing on macos/linux for some
  # reason. This test has been completely refactored in
  # https://github.com/codex-storage/nim-codex/pull/607 in which it will be
  # reintroduced.
  # test "expired request partially pays out for stored time":
  #   let marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
  #   let tokenAddress = await marketplace.token()
  #   let token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
  #   let reward = 400.u256
  #   let duration = 100.u256

  #   # client 2 makes storage available
  #   let startBalanceClient2 = await token.balanceOf(account2)
  #   discard client2.postAvailability(size=140000.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get

  #   # client 1 requests storage but requires two nodes to host the content
  #   let startBalanceClient1 = await token.balanceOf(account1)
  #   let expiry = (await ethProvider.currentTime()) + 10
  #   let cid = client1.upload(exampleString(100000)).get
  #   let id = client1.requestStorage(cid, duration=duration, reward=reward, proofProbability=3.u256, expiry=expiry, collateral=200.u256, nodes=2).get

  #   # We have to wait for Client 2 fills the slot, before advancing time.
  #   # Until https://github.com/codex-storage/nim-codex/issues/594 is implemented nothing better then
  #   # sleeping some seconds is available.
  #   await sleepAsync(2.seconds)
  #   await ethProvider.advanceTimeTo(expiry+1)
  #   check eventually(client1.purchaseStateIs(id, "cancelled"), 20000)

  #   check eventually ((await token.balanceOf(account2)) - startBalanceClient2) > 0 and ((await token.balanceOf(account2)) - startBalanceClient2) < 10*reward
  #   check eventually (startBalanceClient1 - (await token.balanceOf(account1))) == ((await token.balanceOf(account2)) - startBalanceClient2)
