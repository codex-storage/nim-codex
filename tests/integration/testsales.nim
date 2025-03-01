import std/httpclient
import pkg/codex/contracts
import ./twonodes
import ../codex/examples
import ../contracts/time
import ./codexconfig
import ./codexclient
import ./nodeconfigs

proc findItem[T](items: seq[T], item: T): ?!T =
  for tmp in items:
    if tmp == item:
      return success tmp

  return failure("Not found")

multinodesuite "Sales":
  let salesConfig = NodeConfigs(
    clients: CodexConfigs.init(nodes = 1).some,
    providers: CodexConfigs.init(nodes = 1).some,
  )

  let minPricePerBytePerSecond = 1.u256

  var host: CodexClient
  var client: CodexClient

  setup:
    host = providers()[0].client
    client = clients()[0].client

  # test "node handles new storage availability", salesConfig:
  #   let availability1 = host.postAvailability(
  #     totalSize = 1.uint64,
  #     duration = 2.uint64,
  #     minPricePerBytePerSecond = 3.u256,
  #     totalCollateral = 4.u256,
  #   ).get
  #   let availability2 = host.postAvailability(
  #     totalSize = 4.uint64,
  #     duration = 5.uint64,
  #     minPricePerBytePerSecond = 6.u256,
  #     totalCollateral = 7.u256,
  #   ).get
  #   check availability1 != availability2

  # test "node lists storage that is for sale", salesConfig:
  #   let availability = host.postAvailability(
  #     totalSize = 1.uint64,
  #     duration = 2.uint64,
  #     minPricePerBytePerSecond = 3.u256,
  #     totalCollateral = 4.u256,
  #   ).get
  #   check availability in host.getAvailabilities().get

  # test "updating non-existing availability", salesConfig:
  #   let nonExistingResponse = host.patchAvailabilityRaw(
  #     AvailabilityId.example,
  #     duration = 100.uint64.some,
  #     minPricePerBytePerSecond = 2.u256.some,
  #     totalCollateral = 200.u256.some,
  #   )
  #   check nonExistingResponse.status == "404 Not Found"

  # test "updating availability", salesConfig:
  #   let availability = host.postAvailability(
  #     totalSize = 140000.uint64,
  #     duration = 200.uint64,
  #     minPricePerBytePerSecond = 3.u256,
  #     totalCollateral = 300.u256,
  #   ).get

  #   host.patchAvailability(
  #     availability.id,
  #     duration = 100.uint64.some,
  #     minPricePerBytePerSecond = 2.u256.some,
  #     totalCollateral = 200.u256.some,
  #   )

  #   let updatedAvailability = (host.getAvailabilities().get).findItem(availability).get
  #   check updatedAvailability.duration == 100.uint64
  #   check updatedAvailability.minPricePerBytePerSecond == 2
  #   check updatedAvailability.totalCollateral == 200
  #   check updatedAvailability.totalSize == 140000.uint64
  #   check updatedAvailability.freeSize == 140000.uint64

  # test "updating availability - freeSize is not allowed to be changed", salesConfig:
  #   let availability = host.postAvailability(
  #     totalSize = 140000.uint64,
  #     duration = 200.uint64,
  #     minPricePerBytePerSecond = 3.u256,
  #     totalCollateral = 300.u256,
  #   ).get
  #   let freeSizeResponse =
  #     host.patchAvailabilityRaw(availability.id, freeSize = 110000.uint64.some)
  #   check freeSizeResponse.status == "400 Bad Request"
  #   check "not allowed" in freeSizeResponse.body

  # test "updating availability - updating totalSize", salesConfig:
  #   let availability = host.postAvailability(
  #     totalSize = 140000.uint64,
  #     duration = 200.uint64,
  #     minPricePerBytePerSecond = 3.u256,
  #     totalCollateral = 300.u256,
  #   ).get
  #   host.patchAvailability(availability.id, totalSize = 100000.uint64.some)
  #   let updatedAvailability = (host.getAvailabilities().get).findItem(availability).get
  #   check updatedAvailability.totalSize == 100000
  #   check updatedAvailability.freeSize == 100000

  test "updating availability - updating totalSize does not allow bellow utilized",
    salesConfig:
    let originalSize = 0xFFFFFF.uint64
    let data = await RandomChunker.example(blocks = 8)
    let minPricePerBytePerSecond = 3.u256
    let collateralPerByte = 1.u256
    let totalCollateral = originalSize.u256 * collateralPerByte
    let availability = host.postAvailability(
      totalSize = originalSize,
      duration = 20 * 60.uint64,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = totalCollateral,
    ).get

    # Lets create storage request that will utilize some of the availability's space
    let cid = client.upload(data).get
    let id = client.requestStorage(
      cid,
      duration = 20 * 60.uint64,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 3.u256,
      expiry = (10 * 60).uint64,
      collateralPerByte = collateralPerByte,
      nodes = 3,
      tolerance = 1,
    ).get

    check eventually(client.purchaseStateIs(id, "started"), timeout = 10 * 60 * 1000)
    let updatedAvailability = (host.getAvailabilities().get).findItem(availability).get
    check updatedAvailability.totalSize != updatedAvailability.freeSize

    let utilizedSize = updatedAvailability.totalSize - updatedAvailability.freeSize
    let totalSizeResponse =
      host.patchAvailabilityRaw(availability.id, totalSize = (utilizedSize - 1).some)
    check totalSizeResponse.status == "400 Bad Request"
    check "totalSize must be larger then current totalSize" in totalSizeResponse.body

    host.patchAvailability(availability.id, totalSize = (originalSize + 20000).some)
    let newUpdatedAvailability =
      (host.getAvailabilities().get).findItem(availability).get
    check newUpdatedAvailability.totalSize == originalSize + 20000
    check newUpdatedAvailability.freeSize - updatedAvailability.freeSize == 20000
