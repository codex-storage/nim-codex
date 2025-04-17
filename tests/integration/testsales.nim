import std/httpclient
import std/times
import pkg/codex/contracts
from pkg/codex/stores/repostore/types import DefaultQuotaBytes
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
    providers: CodexConfigs.init(nodes = 1)
    # .debug() # uncomment to enable console log output
    # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
    # .withLogTopics("node", "marketplace", "sales", "reservations", "node", "proving", "clock")
    .some,
  )

  var host: CodexClient
  var client: CodexClient

  setup:
    host = providers()[0].client
    client = clients()[0].client

  test "node handles new storage availability", salesConfig:
    let availability1 = (
      await host.postAvailability(
        totalSize = 1.uint64,
        duration = 2.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 4.u256,
      )
    ).get
    let availability2 = (
      await host.postAvailability(
        totalSize = 4.uint64,
        duration = 5.uint64,
        minPricePerBytePerSecond = 6.u256,
        totalCollateral = 7.u256,
      )
    ).get
    check availability1 != availability2

  test "node lists storage that is for sale", salesConfig:
    let availability = (
      await host.postAvailability(
        totalSize = 1.uint64,
        duration = 2.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 4.u256,
      )
    ).get
    check availability in (await host.getAvailabilities()).get

  test "updating availability", salesConfig:
    let availability = (
      await host.postAvailability(
        totalSize = 140000.uint64,
        duration = 200.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 300.u256,
      )
    ).get

    var until = getTime().toUnix()

    await host.patchAvailability(
      availability.id,
      duration = 100.uint64.some,
      minPricePerBytePerSecond = 2.u256.some,
      totalCollateral = 200.u256.some,
      enabled = false.some,
      until = until.some,
    )

    let updatedAvailability =
      ((await host.getAvailabilities()).get).findItem(availability).get
    check updatedAvailability.duration == 100.uint64
    check updatedAvailability.minPricePerBytePerSecond == 2
    check updatedAvailability.totalCollateral == 200
    check updatedAvailability.totalSize == 140000.uint64
    check updatedAvailability.freeSize == 140000.uint64
    check updatedAvailability.enabled == false
    check updatedAvailability.until == until

  test "updating availability - updating totalSize", salesConfig:
    let availability = (
      await host.postAvailability(
        totalSize = 140000.uint64,
        duration = 200.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 300.u256,
      )
    ).get
    await host.patchAvailability(availability.id, totalSize = 100000.uint64.some)

    let updatedAvailability =
      ((await host.getAvailabilities()).get).findItem(availability).get
    check updatedAvailability.totalSize == 100000
    check updatedAvailability.freeSize == 100000

  test "updating availability - updating totalSize does not allow bellow utilized",
    salesConfig:
    let originalSize = 0xFFFFFF.uint64
    let data = await RandomChunker.example(blocks = 8)
    let minPricePerBytePerSecond = 3.u256
    let collateralPerByte = 1.u256
    let totalCollateral = originalSize.u256 * collateralPerByte
    let availability = (
      await host.postAvailability(
        totalSize = originalSize,
        duration = 20 * 60.uint64,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = totalCollateral,
      )
    ).get

    # Lets create storage request that will utilize some of the availability's space
    let cid = (await client.upload(data)).get
    let id = (
      await client.requestStorage(
        cid,
        duration = (20 * 60).stuint(40),
        pricePerBytePerSecond = minPricePerBytePerSecond.stuint(96),
        proofProbability = 3.u256,
        expiry = (10 * 60).stuint(40),
        collateralPerByte = collateralPerByte.stuint(128),
        nodes = 3,
        tolerance = 1,
      )
    ).get

    check eventually(
      await client.purchaseStateIs(id, "started"), timeout = 10 * 60 * 1000
    )
    let updatedAvailability =
      ((await host.getAvailabilities()).get).findItem(availability).get
    check updatedAvailability.totalSize != updatedAvailability.freeSize

    let utilizedSize = updatedAvailability.totalSize - updatedAvailability.freeSize
    let totalSizeResponse = (
      await host.patchAvailabilityRaw(
        availability.id, totalSize = (utilizedSize - 1).some
      )
    )
    check totalSizeResponse.status == 422
    check "totalSize must be larger then current totalSize" in
      (await totalSizeResponse.body)

    await host.patchAvailability(
      availability.id, totalSize = (originalSize + 20000).some
    )
    let newUpdatedAvailability =
      ((await host.getAvailabilities()).get).findItem(availability).get
    check newUpdatedAvailability.totalSize == originalSize + 20000
    check newUpdatedAvailability.freeSize - updatedAvailability.freeSize == 20000

  test "updating availability fails with until negative", salesConfig:
    let availability = (
      await host.postAvailability(
        totalSize = 140000.uint64,
        duration = 200.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 300.u256,
      )
    ).get

    let response =
      await host.patchAvailabilityRaw(availability.id, until = -1.SecondsSince1970.some)

    check:
      (await response.body) == "Cannot set until to a negative value"

  test "returns an error when trying to update the until date before an existing a request is finished",
    salesConfig:
    let size = 0xFFFFFF.uint64
    let data = await RandomChunker.example(blocks = 8)
    let duration = 20 * 60.uint64
    let minPricePerBytePerSecond = 3.u256
    let collateralPerByte = 1.u256
    let ecNodes = 3.uint
    let ecTolerance = 1.uint

    # host makes storage available
    let availability = (
      await host.postAvailability(
        totalSize = size,
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = size.u256 * minPricePerBytePerSecond,
      )
    ).get

    # client requests storage
    let cid = (await client.upload(data)).get
    let id = (
      await client.requestStorage(
        cid,
        duration = duration,
        pricePerBytePerSecond = minPricePerBytePerSecond,
        proofProbability = 3.u256,
        expiry = 10 * 60.uint64,
        collateralPerByte = collateralPerByte,
        nodes = ecNodes,
        tolerance = ecTolerance,
      )
    ).get

    check eventually(
      await client.purchaseStateIs(id, "started"), timeout = 10 * 60 * 1000
    )
    let purchase = (await client.getPurchase(id)).get
    check purchase.error == none string

    let unixNow = getTime().toUnix()
    let until = unixNow + 1.SecondsSince1970

    let response = await host.patchAvailabilityRaw(
      availabilityId = availability.id, until = until.some
    )

    check:
      response.status == 422
      (await response.body) ==
        "Until parameter must be greater or equal to the longest currently hosted slot"
