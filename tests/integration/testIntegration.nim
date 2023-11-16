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
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./twonodes
import ./marketplacesuite


# For debugging you can enable logging output with debugX = true
# You can also pass a string in same format like for the `--log-level` parameter
# to enable custom logging levels for specific topics like: debug2 = "INFO; TRACE: marketplace"

twonodessuite "Integration tests", debug1 = false, debug2 = false:
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
    let currentTime = await provider.currentTime()
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


marketplacesuite "Marketplace payouts":

  test "expired request partially pays out for stored time",
    NodeConfigs(
      # Uncomment to start Hardhat automatically, mainly so logs can be inspected locally
      # hardhat: HardhatConfig().withLogFile()

      clients:
        NodeConfig()
          .nodes(1)
          # .debug() # uncomment to enable console log output.debug()
          # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
          .withLogTopics("node", "erasure"),

      providers:
        NodeConfig()
          .nodes(1)
          # .debug() # uncomment to enable console log output
          # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
          .withLogTopics("marketplace", "sales", "reservations", "node", "clock"),
  ):
    let reward = 400.u256
    let duration = 100.periods
    let collateral = 200.u256
    let expiry = 4.periods
    let data = byteutils.toHex(await exampleData())
    let client = clients()[0]
    let provider = providers()[0]
    let clientApi = client.node.client
    let providerApi = provider.node.client
    let startBalanceProvider = await token.balanceOf(!provider.address)
    let startBalanceClient = await token.balanceOf(!client.address)

    # provider makes storage available
    discard providerApi.postAvailability(
      size=data.len.u256,
      duration=duration.u256,
      minPrice=reward,
      maxCollateral=collateral)

    let cid = clientApi.upload(data).get

    var slotIdxFilled = none UInt256
    proc onSlotFilled(event: SlotFilled) {.upraises:[].} =
      slotIdxFilled = some event.slotIndex
    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # client requests storage but requires two nodes to host the content
    let id = await clientApi.requestStorage(
      cid,
      duration=duration,
      reward=reward,
      expiry=expiry,
      collateral=collateral,
      nodes=2
    )

    # wait until one slot is filled
    check eventually slotIdxFilled.isSome

    # wait until sale is cancelled
    without requestId =? clientApi.requestId(id):
      fail()
    let slotId = slotId(requestId, !slotIdxFilled)
    check eventually(providerApi.saleStateIs(slotId, "SaleCancelled"))

    check eventually (
      let endBalanceProvider = (await token.balanceOf(!provider.address));
      let difference = endBalanceProvider - startBalanceProvider;
      difference > 0 and
      difference < expiry.u256*reward
    )
    check eventually (
      let endBalanceClient = (await token.balanceOf(!client.address));
      let endBalanceProvider = (await token.balanceOf(!provider.address));
      (startBalanceClient - endBalanceClient) == (endBalanceProvider - startBalanceProvider)
    )

    await subscription.unsubscribe()
