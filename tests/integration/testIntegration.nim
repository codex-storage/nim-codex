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

proc findItem[T](items: seq[T], item: T): ?!T =
  for tmp in items:
    if tmp == item:
      return success tmp

  return failure("Not found")

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
    check !client1.info() != !client2.info()

  test "nodes can set chronicles log level":
    client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads":
    let cid1 = client1.upload("some file contents").get
    let cid2 = client1.upload("some other contents").get
    check cid1 != cid2

  test "node shows used and available space":
    discard client1.upload("some file contents").get
    discard client1.postAvailability(totalSize=12.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    let space = client1.space().tryGet()
    check:
      space.totalBlocks == 2.uint
      space.quotaMaxBytes == 8589934592.uint
      space.quotaUsedBytes == 65592.uint
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
      [cid1, cid2].allIt(it in list.content.mapIt(it.cid))

  test "node handles new storage availability":
    let availability1 = client1.postAvailability(totalSize=1.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    let availability2 = client1.postAvailability(totalSize=4.u256, duration=5.u256, minPrice=6.u256, maxCollateral=7.u256).get
    check availability1 != availability2

  test "node lists storage that is for sale":
    let availability = client1.postAvailability(totalSize=1.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    check availability in client1.getAvailabilities().get

  test "node handles storage request":
    let cid = client1.upload("some file contents").get
    let id1 = client1.requestStorage(cid, duration=100.u256, reward=2.u256, proofProbability=3.u256, expiry=10, collateral=200.u256).get
    let id2 = client1.requestStorage(cid, duration=400.u256, reward=5.u256, proofProbability=6.u256, expiry=10, collateral=201.u256).get
    check id1 != id2

  test "node retrieves purchase status":
    # get one contiguous chunk
    let rng = rng.Rng.instance()
    let chunker = RandomChunker.new(rng, size = DefaultBlockSize * 2, chunkSize = DefaultBlockSize * 2)
    let data = await chunker.getBytes()
    let cid = client1.upload(byteutils.toHex(data)).get
    let id = client1.requestStorage(
      cid,
      duration=100.u256,
      reward=2.u256,
      proofProbability=3.u256,
      expiry=30,
      collateral=200.u256,
      nodes=2,
      tolerance=1).get

    let request = client1.getPurchase(id).get.request.get
    check request.ask.duration == 100.u256
    check request.ask.reward == 2.u256
    check request.ask.proofProbability == 3.u256
    check request.expiry == 30
    check request.ask.collateral == 200.u256
    check request.ask.slots == 2'u64
    check request.ask.maxSlotLoss == 1'u64

  # TODO: We currently do not support encoding single chunks
  # test "node retrieves purchase status with 1 chunk":
  #   let cid = client1.upload("some file contents").get
  #   let id = client1.requestStorage(cid, duration=1.u256, reward=2.u256, proofProbability=3.u256, expiry=30, collateral=200.u256, nodes=2, tolerance=1).get
  #   let request = client1.getPurchase(id).get.request.get
  #   check request.ask.duration == 1.u256
  #   check request.ask.reward == 2.u256
  #   check request.ask.proofProbability == 3.u256
  #   check request.expiry == expiry
  #   check request.ask.collateral == 200.u256
  #   check request.ask.slots == 3'u64
  #   check request.ask.maxSlotLoss == 1'u64

  test "node remembers purchase status after restart":
    let cid = client1.upload("some file contents").get
    let id = client1.requestStorage(cid,
                                    duration=100.u256,
                                    reward=2.u256,
                                    proofProbability=3.u256,
                                    expiry=30,
                                    collateral=200.u256).get
    check eventually client1.purchaseStateIs(id, "submitted")

    node1.restart()
    client1.restart()

    check eventually client1.purchaseStateIs(id, "submitted")
    let request = client1.getPurchase(id).get.request.get
    check request.ask.duration == 100.u256
    check request.ask.reward == 2.u256
    check request.ask.proofProbability == 3.u256
    check request.expiry == 30
    check request.ask.collateral == 200.u256
    check request.ask.slots == 1'u64
    check request.ask.maxSlotLoss == 0'u64

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

  test "request storage fails if nodes and tolerance aren't correct":
    let cid = client1.upload("some file contents").get
    let responseBefore = client1.requestStorageRaw(cid,
      duration=100.u256,
      reward=2.u256,
      proofProbability=3.u256,
      expiry=30,
      collateral=200.u256,
      nodes=1,
      tolerance=1)

    check responseBefore.status == "400 Bad Request"
    check responseBefore.body == "Tolerance cannot be greater or equal than nodes (nodes - tolerance)"

  test "node requires expiry and its value to be in future":
    let cid = client1.upload("some file contents").get

    let responseMissing = client1.requestStorageRaw(cid, duration=1.u256, reward=2.u256, proofProbability=3.u256, collateral=200.u256)
    check responseMissing.status == "400 Bad Request"
    check responseMissing.body == "Expiry required"

    let responseBefore = client1.requestStorageRaw(cid, duration=10.u256, reward=2.u256, proofProbability=3.u256, collateral=200.u256, expiry=10)
    check responseBefore.status == "400 Bad Request"
    check "Expiry needs value bigger then zero and smaller then the request's duration" in responseBefore.body

  test "updating non-existing availability":
    let nonExistingResponse = client1.patchAvailabilityRaw(AvailabilityId.example, duration=100.u256.some, minPrice=200.u256.some, maxCollateral=200.u256.some)
    check nonExistingResponse.status == "404 Not Found"

  test "updating availability":
    let availability = client1.postAvailability(totalSize=140000.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get

    client1.patchAvailability(availability.id, duration=100.u256.some, minPrice=200.u256.some, maxCollateral=200.u256.some)

    let updatedAvailability = (client1.getAvailabilities().get).findItem(availability).get
    check updatedAvailability.duration == 100
    check updatedAvailability.minPrice == 200
    check updatedAvailability.maxCollateral == 200
    check updatedAvailability.totalSize == 140000
    check updatedAvailability.freeSize == 140000

  test "updating availability - freeSize is not allowed to be changed":
    let availability = client1.postAvailability(totalSize=140000.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get
    let freeSizeResponse = client1.patchAvailabilityRaw(availability.id, freeSize=110000.u256.some)
    check freeSizeResponse.status == "400 Bad Request"
    check "not allowed" in  freeSizeResponse.body

  test "updating availability - updating totalSize":
    let availability = client1.postAvailability(totalSize=140000.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get
    client1.patchAvailability(availability.id, totalSize=100000.u256.some)
    let updatedAvailability = (client1.getAvailabilities().get).findItem(availability).get
    check updatedAvailability.totalSize == 100000
    check updatedAvailability.freeSize == 100000

  test "updating availability - updating totalSize does not allow bellow utilized":
    let originalSize = 0xFFFFFF.u256
    let data = await RandomChunker.example(blocks=8)
    let availability = client1.postAvailability(totalSize=originalSize, duration=20*60.u256, minPrice=300.u256, maxCollateral=300.u256).get

    # Lets create storage request that will utilize some of the availability's space
    let cid = client2.upload(data).get
    let id = client2.requestStorage(
      cid,
      duration=10*60.u256,
      reward=400.u256,
      proofProbability=3.u256,
      expiry=5*60,
      collateral=200.u256,
      nodes = 5,
      tolerance = 2).get

    check eventually(client2.purchaseStateIs(id, "started"), timeout=5*60*1000)
    let updatedAvailability = (client1.getAvailabilities().get).findItem(availability).get
    check updatedAvailability.totalSize != updatedAvailability.freeSize

    let utilizedSize = updatedAvailability.totalSize - updatedAvailability.freeSize
    let totalSizeResponse = client1.patchAvailabilityRaw(availability.id, totalSize=(utilizedSize-1.u256).some)
    check totalSizeResponse.status == "400 Bad Request"
    check "totalSize must be larger then current totalSize" in totalSizeResponse.body

    client1.patchAvailability(availability.id, totalSize=(originalSize + 20000).some)
    let newUpdatedAvailability = (client1.getAvailabilities().get).findItem(availability).get
    check newUpdatedAvailability.totalSize == originalSize + 20000
    check newUpdatedAvailability.freeSize - updatedAvailability.freeSize == 20000
