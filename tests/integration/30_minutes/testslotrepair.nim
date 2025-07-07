import pkg/questionable
import pkg/codex/logutils
import ../../contracts/time
import ../../contracts/deployment
import ../../codex/helpers
import ../../examples
import ../marketplacesuite
import ../nodeconfigs

export logutils

logScope:
  topics = "integration test slot repair"

marketplacesuite(name = "SP Slot Repair"):
  const minPricePerBytePerSecond = 1.u256
  const collateralPerByte = 1.u256
  const blocks = 3
  const ecNodes = 3
  const ecTolerance = 1
  const size = slotSize(blocks, ecNodes, ecTolerance)

  var freedSlotIndex = none uint64
  var requestId: RequestId
  var slotFilledEvent: AsyncEvent

  # Here we are keeping track of the slot filled using their ids.
  proc onSlotFilled(eventResult: ?!SlotFilled) =
    assert not eventResult.isErr
    let event = !eventResult

    if event.requestId == requestId and event.slotIndex == freedSlotIndex.get:
      slotFilledEvent.fire()

  # Here we are retrieving the slot id freed.
  # When the event is triggered, the slot id is removed
  # from the filled slot id list.
  proc onSlotFreed(eventResult: ?!SlotFreed) =
    assert not eventResult.isErr
    let event = !eventResult
    let slotId = slotId(event.requestId, event.slotIndex)

    if event.requestId == requestId:
      freedSlotIndex = some event.slotIndex

  proc freeSlot(provider: CodexProcess): Future[void] {.async.} =
    # Get the second provider signer.
    let signer = ethProvider.getSigner(provider.ethAccount)
    let marketplaceWithSecondProviderSigner = marketplace.connect(signer)

    # Call freeSlot to speed up the process.
    # It accelerates the test by skipping validator
    # proof verification and not waiting for the full period.
    # The downside is that this doesn't reflect the real slot freed process.
    let slots = (await provider.client.getSlots()).get()
    let slotId = slotId(requestId, slots[0].slotIndex)
    discard await marketplaceWithSecondProviderSigner.freeSlot(slotId)

  setup:
    slotFilledEvent = newAsyncEvent()

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

    let (purchaseId, id) = await requestStorage(
      client0.client,
      blocks = blocks,
      expiry = expiry,
      duration = duration,
      proofProbability = 1.u256,
    )
    requestId = id

    # Wait for purchase starts, meaning that the slots are filled.
    await waitForRequestToStart(requestId, expiry.int64)

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

    await marketplaceSubscribe(SlotFilled, onSlotFilled)
    await marketplaceSubscribe(SlotFreed, onSlotFreed)

    # Let's free the slot to speed up the process
    await freeSlot(provider1)

    # We expect that the freed slot is filled again,
    # meaning that the slot was repaired locally by SP 1.
    let secondsTillRequestEnd = await getSecondsTillRequestEnd(requestId)
    await slotFilledEvent.wait().wait(timeout = chronos.seconds(secondsTillRequestEnd))

  test "repair from local and remote store",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        # .debug()
        .withLogFile()
        .withLogTopics("node", "erasure").some,
      providers: CodexConfigs
        .init(nodes = 3)
        # .debug()
        .withLogFile()
        .withLogTopics("marketplace", "sales", "statemachine", "reservations").some,
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

    let (purchaseId, id) = await requestStorage(
      client0.client,
      blocks = blocks,
      expiry = expiry,
      duration = duration,
      proofProbability = 1.u256,
    )
    requestId = id

    # Wait for purchase starts, meaning that the slots are filled.
    await waitForRequestToStart(requestId, expiry.int64)

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

    await marketplaceSubscribe(SlotFilled, onSlotFilled)
    await marketplaceSubscribe(SlotFreed, onSlotFreed)

    # Let's free the slot to speed up the process
    await freeSlot(provider1)

    # We expect that the freed slot is filled again,
    # meaning that the slot was repaired locally and remotely (using SP 3) by SP 1.
    let secondsTillRequestEnd = await getSecondsTillRequestEnd(requestId)
    await slotFilledEvent.wait().wait(timeout = chronos.seconds(secondsTillRequestEnd))

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

    let (purchaseId, id) = await requestStorage(
      client0.client,
      blocks = blocks,
      expiry = expiry,
      duration = duration,
      proofProbability = 1.u256,
    )
    requestId = id

    # Wait for purchase starts, meaning that the slots are filled.
    await waitForRequestToStart(requestId, expiry.int64)

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

    await marketplaceSubscribe(SlotFilled, onSlotFilled)
    await marketplaceSubscribe(SlotFreed, onSlotFreed)

    # Let's free the slot to speed up the process
    await freeSlot(provider1)

    # At this point, SP 3 should repair the slot from SP 1 and host it.
    let secondsTillRequestEnd = await getSecondsTillRequestEnd(requestId)
    await slotFilledEvent.wait().wait(timeout = chronos.seconds(secondsTillRequestEnd))
