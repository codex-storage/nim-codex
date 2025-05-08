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
  const ecNodes = 3
  const ecTolerance = 1

  test "repair from local store",
    NodeConfigs(
      clients: CodexConfigs.init(nodes = 1).some,
        # .debug()
        # .withLogFile()
        # .withLogTopics("node", "erasure").some,
      providers: CodexConfigs
        .init(nodes = 2)
        .withSimulateProofFailures(idx = 1, failEveryNProofs = 1)
        # .debug()
        .withLogFile()
        .withLogTopics("marketplace", "sales", "reservations", "statemachine").some,
      validators: CodexConfigs.init(nodes = 1).some,
        # .debug()
        # .withLogFile()
        # .withLogTopics("validator").some,
    ):
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let expiry = 10.periods
    let duration = expiry + 10.periods

    let data = await RandomChunker.example(blocks = blocks)
    let slotSize = slotSize(blocks, ecNodes, ecTolerance)

    # Let's create 2 availabilities
    # The first host will be able to host 2 slots with a
    # total collateral for 3 slots for later.
    # The second one, sending invalid proofs, will be able
    # to host one slot.
    let availability0 = (
      await provider0.client.postAvailability(
        totalSize = 2 * slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 3 * slotSize * collateralPerByte,
      )
    ).get
    let availability1 = (
      await provider1.client.postAvailability(
        totalSize = slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = slotSize * collateralPerByte,
      )
    ).get

    let cid = (await client0.client.upload(data)).get

    let purchaseId = await client0.client.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      nodes = ecNodes,
      tolerance = ecTolerance,
      collateralPerByte = 1.u256,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 1.u256,
    )

    let requestId = (await client0.client.requestId(purchaseId)).get

    # Here we are keeping track of the slot filled using their ids.
    var filledSlotIds: seq[SlotId] = @[]
    proc onSlotFilled(eventResult: ?!SlotFilled) =
      assert not eventResult.isErr
      let event = !eventResult

      if event.requestId == requestId:
        let slotId = slotId(event.requestId, event.slotIndex)
        filledSlotIds.add slotId

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # Here we are retrieving the slot id freed.
    # When the event is triggered, the slot id is removed 
    # from the filled slot id list.
    var freedSlotId = none SlotId
    proc onSlotFreed(eventResult: ?!SlotFreed) =
      assert not eventResult.isErr
      let event = !eventResult

      if event.requestId == requestId:
        let slotId = slotId(event.requestId, event.slotIndex)
        assert slotId in filledSlotIds
        filledSlotIds.del(filledSlotIds.find(slotId))
        freedSlotId = some(slotId)

    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # Wait for purchase starts, meaning that the slots are filled.
    check eventually(
      await client0.client.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000
    )

    # stop client so it doesn't serve any blocks anymore
    await client0.stop()

    # Let's disable the second availability in order to not let
    # the second host pick the slot again.
    await provider1.client.patchAvailability(
      availabilityId = availability1.id, enabled = false.some
    )

    # Update the size of the availability for the first host, 
    # in order the store the freed slot.
    await provider0.client.patchAvailability(
      availabilityId = availability0.id,
      totalSize = (3 * slotSize.truncate(uint64)).uint64.some,
    )

    check eventually(freedSlotId.isSome, timeout = (duration - expiry).int * 1000)

    # We expect that the freed slot is added in the filled slot id list, 
    # meaning that the slot was repaired by the first host and filled. 
    check eventually(
      freedSlotId.get in filledSlotIds, timeout = (duration - expiry).int * 1000
    )

    await filledSubscription.unsubscribe()
    await slotFreedsubscription.unsubscribe()

  test "repair from remote store",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        # .debug()
        .withLogTopics("node", "erasure").some,
      providers: CodexConfigs
        .init(nodes = 3)
        .withSimulateProofFailures(idx = 1, failEveryNProofs = 1)
        .debug()
        .withLogFile()
        .withLogTopics("marketplace", "sales", "statemachine", "reservations").some,
      validators: CodexConfigs.init(nodes = 1)
      # .withLogTopics("validator")
      # .debug()
      .some,
    ):
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let provider2 = providers()[2]
    let expiry = 10.periods
    let duration = expiry + 10.periods

    let data = await RandomChunker.example(blocks = blocks)
    let slotSize = slotSize(blocks, ecNodes, ecTolerance)
    let datasetSize =
      datasetSize(blocks = blocks, nodes = ecNodes, tolerance = ecTolerance)

    # Let's create an availability capable to store one slot
    let availability0 = (
      await provider0.client.postAvailability(
        totalSize = slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 100 * slotSize * collateralPerByte,
      )
    ).get
    let availability1 = (
      await provider1.client.postAvailability(
        totalSize = slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 100 * slotSize * collateralPerByte,
      )
    ).get
    discard await provider2.client.postAvailability(
      totalSize = slotSize.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 100 * slotSize * collateralPerByte,
    )

    let cid = (await client0.client.upload(data)).get

    let purchaseId = await client0.client.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      nodes = ecNodes,
      tolerance = ecTolerance,
      collateralPerByte = 1.u256,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 1.u256,
    )
    let requestId = (await client0.client.requestId(purchaseId)).get

    # Here we are keeping track of the slot filled using their ids.
    var filledSlotIds: seq[SlotId] = @[]
    proc onSlotFilled(eventResult: ?!SlotFilled) =
      assert not eventResult.isErr
      let event = !eventResult

      if event.requestId == requestId:
        let slotId = slotId(event.requestId, event.slotIndex)
        filledSlotIds.add slotId

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # Here we are retrieving the slot id freed.
    # When the event is triggered, the slot id is removed 
    # from the filled slot id list.
    var freedSlotId = none SlotId
    proc onSlotFreed(eventResult: ?!SlotFreed) =
      assert not eventResult.isErr
      let event = !eventResult
      let slotId = slotId(event.requestId, event.slotIndex)

      if event.requestId == requestId:
        assert slotId in filledSlotIds
        filledSlotIds.del(filledSlotIds.find(slotId))
        freedSlotId = some(slotId)

    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    check eventually(
      await client0.client.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000
    )

    # stop client so it doesn't serve any blocks anymore
    await client0.stop()

    await provider1.client.patchAvailability(availability1.id, enabled = false.some)

    await provider0.client.patchAvailability(
      availability0.id, totalSize = (2 * slotSize.truncate(uint64)).some
    )

    check eventually(freedSlotId.isSome, timeout = expiry.int * 1000)

    check eventually(freedSlotId.get in filledSlotIds, timeout = expiry.int * 1000)

    await filledSubscription.unsubscribe()
    await slotFreedsubscription.unsubscribe()

  test "repair to empty sp",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        #.debug()
        #.withLogTopics("node", "erasure")
        .some,
      providers: CodexConfigs
        .init(nodes = 3)
        .withSimulateProofFailures(idx = 1, failEveryNProofs = 1)
        .debug()
        .withLogFile()
        .withLogTopics("marketplace", "sales", "statemachine", "reservations").some,
      validators: CodexConfigs.init(nodes = 1)
      # .withLogTopics("validator")
      # .debug()
      .some,
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
        totalSize = 2 * slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 100 * slotSize * collateralPerByte,
      )
    let availability1 = (
      await provider1.client.postAvailability(
        totalSize = slotSize.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 100 * slotSize * collateralPerByte,
      )
    ).get

    let cid = (await client0.client.upload(data)).get

    let purchaseId = await client0.client.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      nodes = ecNodes,
      tolerance = ecTolerance,
      collateralPerByte = 1.u256,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 1.u256,
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

    var freedSlotId = none SlotId
    proc onSlotFreed(eventResult: ?!SlotFreed) =
      assert not eventResult.isErr
      let event = !eventResult
      let slotId = slotId(event.requestId, event.slotIndex)

      if event.requestId == requestId:
        assert slotId in filledSlotIds
        filledSlotIds.del(filledSlotIds.find(slotId))
        freedSlotId = some(slotId)

    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

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

    await provider1.client.patchAvailability(availability1.id, enabled = false.some)

    check eventually(freedSlotId.isSome, timeout = expiry.int * 1000)

    check eventually(freedSlotId.get in filledSlotIds, timeout = expiry.int * 1000)

    await filledSubscription.unsubscribe()
    await slotFreedsubscription.unsubscribe()

  # test "storage provider slot repair",
  #   NodeConfigs(
  #     clients: CodexConfigs
  #       .init(nodes = 1)
  #       .debug()
  #       .withLogFile()
  #       .withLogTopics("node", "erasure").some,
  #     providers: CodexConfigs
  #       .init(nodes = 4)
  #       .debug()
  #       .withLogFile()
  #       .withLogTopics("marketplace", "sales", "reservations", "node").some,
  #     validators: CodexConfigs
  #       .init(nodes = 1)
  #       .debug()
  #       .withLogFile()
  #       .withLogTopics("validator").some,
  #   ):
  #   let client0 = clients()[0].client
  #   let expiry = 10.periods
  #   let duration = expiry + 10.periods
  #   let size = 0xFFFFFF.uint64

  #   let data = await RandomChunker.example(blocks = blocks)
  #   let datasetSize =
  #     datasetSize(blocks = blocks, nodes = ecNodes, tolerance = ecTolerance)

  #   await createAvailabilities(
  #     size, duration, datasetSize * collateralPerByte, minPricePerBytePerSecond
  #   )

  #   let cid = (await client0.upload(data)).get

  #   let purchaseId = await client0.requestStorage(
  #     cid,
  #     expiry = expiry,
  #     duration = duration,
  #     collateralPerByte = collateralPerByte,
  #     nodes = ecNodes,
  #     tolerance = ecTolerance,
  #     proofProbability = 1.u256,
  #     pricePerBytePerSecond = minPricePerBytePerSecond,
  #   )

  #   let requestId = (await client0.requestId(purchaseId)).get

  #   var filledSlotIds: seq[SlotId] = @[]
  #   proc onSlotFilled(eventResult: ?!SlotFilled) =
  #     assert not eventResult.isErr
  #     let event = !eventResult
  #     if event.requestId == requestId:
  #       let slotId = slotId(event.requestId, event.slotIndex)
  #       filledSlotIds.add slotId

  #   let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

  #   check eventually(
  #     await client0.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 100
  #   )

  #   check eventually(
  #     filledSlotIds.len == blocks, timeout = (duration - expiry).int * 100
  #   )
  #   trace "all slots have been filled"

  #   var slotWasFreed = false
  #   proc onSlotFreed(event: ?!SlotFreed) =
  #     if event.isOk and event.value.requestId == requestId:
  #       trace "slot was freed", slotIndex = $event.value.slotIndex
  #       slotWasFreed = true

  #   let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

  #   block provider_search:
  #     while true:
  #       for slotId in filledSlotIds:
  #         for provider in providers():
  #           if (await provider.client.saleStateIs(slotId, "SaleProving")):
  #             await provider.stop()
  #             break provider_search
  #       await sleepAsync(100.milliseconds)

  #   check eventually(slotWasFreed, timeout = (duration - expiry).int * 100)

  #   await slotFreedsubscription.unsubscribe()

  #   check eventually(
  #     filledSlotIds.len > blocks, timeout = (duration - expiry).int * 100
  #   )
  #   trace "freed slot was filled"

  #   await filledSubscription.unsubscribe()
