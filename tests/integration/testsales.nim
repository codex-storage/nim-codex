import std/httpclient
import pkg/codex/contracts
from pkg/codex/stores/repostore/types import DefaultQuotaBytes
import ./twonodes
import ../codex/examples
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
    clients: CodexConfigs
      .init(nodes = 1)
      .withLogFile()
      .withLogTopics(
        "node", "marketplace", "sales", "reservations", "node", "proving", "clock"
      ).some,
    providers: CodexConfigs
      .init(nodes = 1)
      .withLogFile()
      .withLogTopics(
        "node", "marketplace", "sales", "reservations", "node", "proving", "clock"
      ).some,
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
        duration = 2'StorageDuration,
        minPricePerBytePerSecond = 3'TokensPerSecond,
        totalCollateral = 4'Tokens,
      )
    ).get
    let availability2 = (
      await host.postAvailability(
        totalSize = 4.uint64,
        duration = 5'StorageDuration,
        minPricePerBytePerSecond = 6'TokensPerSecond,
        totalCollateral = 7'Tokens,
      )
    ).get
    check availability1 != availability2

  test "node lists storage that is for sale", salesConfig:
    let availability = (
      await host.postAvailability(
        totalSize = 1.uint64,
        duration = 2'StorageDuration,
        minPricePerBytePerSecond = 3'TokensPerSecond,
        totalCollateral = 4'Tokens,
      )
    ).get
    check availability in (await host.getAvailabilities()).get

  test "updating availability", salesConfig:
    let availability = (
      await host.postAvailability(
        totalSize = 140000.uint64,
        duration = 200'StorageDuration,
        minPricePerBytePerSecond = 3'TokensPerSecond,
        totalCollateral = 300'Tokens,
      )
    ).get

    await host.patchAvailability(
      availability.id,
      duration = some 100'StorageDuration,
      minPricePerBytePerSecond = some 2'TokensPerSecond,
      totalCollateral = some 200'Tokens,
    )

    let updatedAvailability =
      ((await host.getAvailabilities()).get).findItem(availability).get
    check updatedAvailability.duration == 100'StorageDuration
    check updatedAvailability.minPricePerBytePerSecond == 2'TokensPerSecond
    check updatedAvailability.totalCollateral == 200'Tokens
    check updatedAvailability.totalSize == 140000.uint64
    check updatedAvailability.freeSize == 140000.uint64

  test "updating availability - updating totalSize", salesConfig:
    let availability = (
      await host.postAvailability(
        totalSize = 140000.uint64,
        duration = 200'StorageDuration,
        minPricePerBytePerSecond = 3'TokensPerSecond,
        totalCollateral = 300'Tokens,
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
    let minPricePerBytePerSecond = 3'TokensPerSecond
    let collateralPerByte = 1'Tokens
    let totalCollateral = collateralPerByte * originalSize
    let availability = (
      await host.postAvailability(
        totalSize = originalSize,
        duration = StorageDuration.init(20'u32 * 60),
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = totalCollateral,
      )
    ).get

    # Lets create storage request that will utilize some of the availability's space
    let cid = (await client.upload(data)).get
    let id = (
      await client.requestStorage(
        cid,
        duration = StorageDuration.init(20'u32 * 60),
        pricePerBytePerSecond = minPricePerBytePerSecond,
        proofProbability = 3.u256,
        expiry = StorageDuration.init(10'u32 * 60),
        collateralPerByte = collateralPerByte,
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
