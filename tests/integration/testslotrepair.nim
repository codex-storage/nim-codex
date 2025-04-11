import pkg/questionable
import pkg/codex/logutils
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./marketplacesuite
import ./nodeconfigs

export logutils

logScope:
  topics = "integration test slot repair"

marketplacesuite "SP Slot Repair":
  const minPricePerBytePerSecond = 1.u256
  const collateralPerByte = 1.u256
  const blocks = 3
  const ecNodes = 5
  const ecTolerance = 2

  test "repair from local store",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        .debug()
        .withLogFile()
        .withLogTopics("node", "erasure").some,
      providers: CodexConfigs
        .init(nodes = 2)
        .withSimulateProofFailures(idx = 1, failEveryNProofs = 1)
        .debug()
        .withLogFile()
        .withLogTopics("marketplace", "sales", "reservations", "node", "statemachine").some,
      validators: CodexConfigs
        .init(nodes = 1)
        .debug()
        .withLogFile()
        .withLogTopics("validator").some,
    ):
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let expiry = 10.periods
    let duration = expiry + 10.periods

    let data = await RandomChunker.example(blocks = blocks)
    let slotSize = slotSize(blocks, ecNodes, ecTolerance)

    let availability = (
      await provider0.client.postAvailability(
        totalSize = 4 * slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 100 * slotSize * collateralPerByte,
      )
    ).get

    discard await provider1.client.postAvailability(
      totalSize = slotSize.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 100 * slotSize * collateralPerByte,
    )

    var filledSlotIds: seq[SlotId] = @[]
    proc onSlotFilled(eventResult: ?!SlotFilled) =
      assert not eventResult.isErr
      let event = !eventResult
      let slotId = slotId(event.requestId, event.slotIndex)
      filledSlotIds.add slotId

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    var freedSlotId = none SlotId
    proc onSlotFreed(eventResult: ?!SlotFreed) =
      assert not eventResult.isErr
      let event = !eventResult
      let slotId = slotId(event.requestId, event.slotIndex)

      assert slotId in filledSlotIds

      filledSlotIds.del(filledSlotIds.find(slotId))
      freedSlotId = some(slotId)

    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    let cid = (await client0.client.upload(data)).get

    let purchaseId = await client0.client.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      nodes = ecNodes,
      tolerance = ecTolerance,
      proofProbability = 1.u256,
    )

    check eventually(
      await client0.client.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000
    )

    await client0.stop()

    await provider0.client.patchAvailability(
      availabilityId = availability.id,
      totalSize = (5 * slotSize.truncate(uint64)).uint64.some,
      duration = duration.uint64.some,
      minPricePerBytePerSecond = minPricePerBytePerSecond.some,
      totalCollateral = (100 * slotSize * collateralPerByte).some,
    )

    check eventually(freedSlotId.isSome, timeout = (duration - expiry).int * 1000)

    check eventually(
      freedSlotId.get in filledSlotIds, timeout = (duration - expiry).int * 1000
    )

    await filledSubscription.unsubscribe()
    await slotFreedsubscription.unsubscribe()

  test "repair from remote store",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        .debug()
        .withLogFile()
        .withLogTopics("node", "erasure").some,
      providers: CodexConfigs
        .init(nodes = 3)
        .withSimulateProofFailures(idx = 1, failEveryNProofs = 1)
        .debug()
        .withLogFile()
        .withLogTopics("marketplace", "sales", "reservations", "node", "statemachine").some,
      validators: CodexConfigs
        .init(nodes = 1)
        .debug()
        .withLogFile()
        .withLogTopics("validator").some,
    ):
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let provider2 = providers()[2]
    let expiry = 10.periods
    let duration = expiry + 10.periods

    let data = await RandomChunker.example(blocks = blocks)
    let slotSize = slotSize(blocks, ecNodes, ecTolerance)

    discard await provider0.client.postAvailability(
        totalSize = 4 * slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 100 * slotSize * collateralPerByte,
      )

    discard await provider1.client.postAvailability(
      totalSize = slotSize.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 100 * slotSize * collateralPerByte,
    )

    var filledSlotIds: seq[SlotId] = @[]
    proc onSlotFilled(eventResult: ?!SlotFilled) =
      assert not eventResult.isErr
      let event = !eventResult
      let slotId = slotId(event.requestId, event.slotIndex)
      filledSlotIds.add slotId

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    var freedSlotId = none SlotId
    proc onSlotFreed(eventResult: ?!SlotFreed) =
      assert not eventResult.isErr
      let event = !eventResult
      let slotId = slotId(event.requestId, event.slotIndex)

      assert slotId in filledSlotIds

      filledSlotIds.del(filledSlotIds.find(slotId))
      freedSlotId = some(slotId)

    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    let cid = (await client0.client.upload(data)).get

    let purchaseId = await client0.client.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      nodes = ecNodes,
      tolerance = ecTolerance,
      proofProbability = 1.u256,
    )

    check eventually(
      await client0.client.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000
    )

    await client0.stop()

    discard await provider2.client.postAvailability(
        totalSize = slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 100 * slotSize * collateralPerByte,
      )

    check eventually(freedSlotId.isSome, timeout = (duration - expiry).int * 1000)

    await provider1.stop()

    check eventually(
      freedSlotId.get in filledSlotIds, timeout = (duration - expiry).int * 1000
    )

    await filledSubscription.unsubscribe()
    await slotFreedsubscription.unsubscribe()

  test "storage provider slot repair",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        .debug()
        .withLogFile()
        .withLogTopics("node", "erasure").some,
      providers: CodexConfigs
        .init(nodes = 4)
        .debug()
        .withLogFile()
        .withLogTopics("marketplace", "sales", "reservations", "node").some,
      validators: CodexConfigs
        .init(nodes = 1)
        .debug()
        .withLogFile()
        .withLogTopics("validator").some,
    ):
    let client0 = clients()[0]
    let expiry = 10.periods
    let duration = expiry + 10.periods
    let size = 0xFFFFFF.uint64

    let data = await RandomChunker.example(blocks = blocks)
    let datasetSize =
      datasetSize(blocks = blocks, nodes = ecNodes, tolerance = ecTolerance)

    await createAvailabilities(
      size, duration, datasetSize * collateralPerByte, minPricePerBytePerSecond
    )

    let cid = (await client0.client.upload(data)).get

    let purchaseId = await client0.client.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      collateralPerByte = collateralPerByte,
      nodes = ecNodes,
      tolerance = ecTolerance,
      proofProbability = 1.u256,
      pricePerBytePerSecond = minPricePerBytePerSecond,
    )

    let requestId = (await client0.client.requestId(purchaseId)).get

    var filledSlotIds: seq[SlotId] = @[]
    proc onSlotFilled(eventResult: ?!SlotFilled) =
      assert not eventResult.isErr
      let event = !eventResult
      if event.requestId == requestId:
        let slotId = slotId(event.requestId, event.slotIndex)
        filledSlotIds.add slotId

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    check eventually(
      await client0.client.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000
    )

    await client0.stop()

    check eventually(
      filledSlotIds.len == blocks, timeout = (duration - expiry).int * 1000
    )
    trace "all slots have been filled"

    var slotWasFreed = false
    proc onSlotFreed(event: ?!SlotFreed) =
      if event.isOk and event.value.requestId == requestId:
        trace "slot was freed", slotIndex = $event.value.slotIndex
        slotWasFreed = true

    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    block provider_search:
      while true:
        for slotId in filledSlotIds:
          for provider in providers():
            if (await provider.client.saleStateIs(slotId, "SaleProving")):
              await provider.stop()
              break provider_search
        await sleepAsync(100.milliseconds)

    check eventually(slotWasFreed, timeout = (duration - expiry).int * 1000)

    await slotFreedsubscription.unsubscribe()

    check eventually(
      filledSlotIds.len > blocks, timeout = (duration - expiry).int * 1000
    )
    trace "freed slot was filled"

    await filledSubscription.unsubscribe()
