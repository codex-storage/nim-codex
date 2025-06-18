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

marketplacesuite(name = "SP Slot Repair", stopOnRequestFail = true):
  const minPricePerBytePerSecond = 1.u256
  const collateralPerByte = 1.u256
  const blocks = 3
  const ecNodes = 3
  const ecTolerance = 1
  const size = slotSize(blocks, ecNodes, ecTolerance)

  var filledSlotIds: seq[SlotId] = @[]
  var freedSlotId = none SlotId
  var requestId: RequestId

  # Here we are keeping track of the slot filled using their ids.
  proc onSlotFilled(eventResult: ?!SlotFilled) =
    assert not eventResult.isErr
    let event = !eventResult

    if event.requestId == requestId:
      let slotId = slotId(event.requestId, event.slotIndex)
      filledSlotIds.add slotId

  # Here we are retrieving the slot id freed.
  # When the event is triggered, the slot id is removed
  # from the filled slot id list.
  proc onSlotFreed(eventResult: ?!SlotFreed) =
    assert not eventResult.isErr
    let event = !eventResult
    let slotId = slotId(event.requestId, event.slotIndex)

    if event.requestId == requestId:
      assert slotId in filledSlotIds
      filledSlotIds.del(filledSlotIds.find(slotId))
      freedSlotId = some(slotId)

  proc createPurchase(client: CodexClient): Future[PurchaseId] {.async.} =
    let data = await RandomChunker.example(blocks = blocks)
    let cid = (await client.upload(data)).get

    let purchaseId = await client.requestStorage(
      cid,
      expiry = 10.periods,
      duration = 20.periods,
      nodes = ecNodes,
      tolerance = ecTolerance,
      collateralPerByte = 1.u256,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 1.u256,
    )
    requestId = (await client.requestId(purchaseId)).get

    return purchaseId

  proc freeSlot(provider: CodexClient): Future[void] {.async.} =
    # Get the second provider signer.
    let signer = ethProvider.getSigner(accounts[2])
    let marketplaceWithSecondProviderSigner = marketplace.connect(signer)

    # Call freeSlot to speed up the process.
    # It accelerates the test by skipping validator
    # proof verification and not waiting for the full period.
    # The downside is that this doesn't reflect the real slot freed process.
    let slots = (await provider.getSlots()).get()
    let slotId = slotId(requestId, slots[0].slotIndex)
    discard await marketplaceWithSecondProviderSigner.freeSlot(slotId)

  setup:
    filledSlotIds = @[]
    freedSlotId = none SlotId

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
    let duration = 20.periods

    # Let's create 2 availabilities
    # SP 1 will hosts 2 slots
    # SP 2 will hosts 1 slot
    let availability0 = (
      await provider0.client.postAvailability(
        totalSize = 2 * size.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = 3 * size * collateralPerByte,
      )
    ).get
    let availability1 = (
      await provider1.client.postAvailability(
        totalSize = size.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = size * collateralPerByte,
      )
    ).get

    let purchaseId = await createPurchase(client0.client)

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)
    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # Wait for purchase starts, meaning that the slots are filled.
    discard await waitForRequestToStart(expiry.int)

    # stop client so it doesn't serve any blocks anymore
    await client0.stop()

    # Let's disable the second availability,
    # SP 2 will not pick the slot again.
    await provider1.client.patchAvailability(
      availabilityId = availability1.id, enabled = false.some
    )

    # Update the size of the availability for the SP 1,
    # he will repair and host the freed slot
    await provider0.client.patchAvailability(
      availabilityId = availability0.id,
      totalSize = (3 * size.truncate(uint64)).uint64.some,
    )

    # Let's free the slot to speed up the process
    await freeSlot(provider1.client)

    # We expect that the freed slot is added in the filled slot id list, 
    # meaning that the slot was repaired locally by SP 1.
    check eventually(
      freedSlotId.get in filledSlotIds, timeout = (duration - expiry).int * 1000
    )

    await filledSubscription.unsubscribe()
    await slotFreedsubscription.unsubscribe()

  test "repair from local and remote store",
    NodeConfigs(
      clients: CodexConfigs.init(nodes = 1)
      # .debug()
      # .withLogTopics("node", "erasure")
      .some,
      providers: CodexConfigs.init(nodes = 3)
      # .debug()
      # .withLogFile()
      # .withLogTopics("marketplace", "sales", "statemachine", "reservations")
      .some,
    ):
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let provider2 = providers()[2]
    let expiry = 10.periods
    let duration = 20.periods

    # SP 1, SP 2 and SP 3 will host one slot
    let availability0 = (
      await provider0.client.postAvailability(
        totalSize = size.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = size * collateralPerByte,
      )
    ).get
    let availability1 = (
      await provider1.client.postAvailability(
        totalSize = size.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = size * collateralPerByte,
      )
    ).get
    discard await provider2.client.postAvailability(
      totalSize = size.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = size * collateralPerByte,
    )

    let purchaseId = await createPurchase(client0.client)

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)
    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # Wait for purchase starts, meaning that the slots are filled.
    discard await waitForRequestToStart(expiry.int)

    # stop client so it doesn't serve any blocks anymore
    await client0.stop()

    # Let's disable the availability,
    # SP 2 will not pick the slot again.
    await provider1.client.patchAvailability(availability1.id, enabled = false.some)

    # Update the size of the availability for the SP 1,
    # he will repair and host the freed slot
    await provider0.client.patchAvailability(
      availability0.id,
      totalSize = (2 * size.truncate(uint64)).some,
      totalCollateral = (2 * size * collateralPerByte).some,
    )

    # Let's free the slot to speed up the process
    await freeSlot(provider1.client)

    # We expect that the freed slot is added in the filled slot id list,
    # meaning that the slot was repaired locally and remotely (using SP 3) by SP 1.
    check eventually(freedSlotId.isSome, timeout = expiry.int * 1000)
    check eventually(freedSlotId.get in filledSlotIds, timeout = expiry.int * 1000)

    await filledSubscription.unsubscribe()
    await slotFreedsubscription.unsubscribe()

  test "repair from remote store only",
    NodeConfigs(
      clients: CodexConfigs.init(nodes = 1)
      # .debug()
      #   .withLogFile()
      # .withLogTopics("node", "erasure")
      .some,
      providers: CodexConfigs.init(nodes = 3)
      # .debug()
      # .withLogFile()
      # .withLogTopics("marketplace", "sales", "statemachine", "reservations")
      .some,
    ):
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let provider2 = providers()[2]
    let expiry = 10.periods
    let duration = expiry + 10.periods

    # SP 1 will host 2 slots
    # SP 2 will host 1 slot
    discard await provider0.client.postAvailability(
      totalSize = 2 * size.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 2 * size * collateralPerByte,
    )
    let availability1 = (
      await provider1.client.postAvailability(
        totalSize = size.truncate(uint64),
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = size * collateralPerByte,
      )
    ).get

    let purchaseId = await createPurchase(client0.client)

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)
    let slotFreedsubscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # Wait for purchase starts, meaning that the slots are filled.
    discard await waitForRequestToStart(expiry.int)

    # stop client so it doesn't serve any blocks anymore
    await client0.stop()

    # Let's create an availability for SP3,
    # he will host the repaired slot.
    discard await provider2.client.postAvailability(
      totalSize = size.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = size * collateralPerByte,
    )

    # Let's disable the availability,
    # SP 2 will not pick the slot again.
    await provider1.client.patchAvailability(availability1.id, enabled = false.some)

    # Let's free the slot to speed up the process
    await freeSlot(provider1.client)

    # At this point, SP 3 should repair the slot from SP 1 and host it.
    check eventually(freedSlotId.isSome, timeout = expiry.int * 1000)
    check eventually(freedSlotId.get in filledSlotIds, timeout = expiry.int * 1000)

    await filledSubscription.unsubscribe()
    await slotFreedsubscription.unsubscribe()
