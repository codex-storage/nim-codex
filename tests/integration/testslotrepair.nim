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
    let client0 = clients()[0].client
    let expiry = 10.periods
    let duration = expiry + 10.periods
    let size = 0xFFFFFF.uint64

    let data = await RandomChunker.example(blocks = blocks)
    let datasetSize =
      datasetSize(blocks = blocks, nodes = ecNodes, tolerance = ecTolerance)

    await createAvailabilities(
      size, duration, datasetSize * collateralPerByte, minPricePerBytePerSecond
    )

    let cid = (await client0.upload(data)).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      collateralPerByte = collateralPerByte,
      nodes = ecNodes,
      tolerance = ecTolerance,
      proofProbability = 1.u256,
      pricePerBytePerSecond = minPricePerBytePerSecond,
    )

    let requestId = (await client0.requestId(purchaseId)).get

    var filledSlotIds: seq[SlotId] = @[]
    proc onSlotFilled(eventResult: ?!SlotFilled) =
      assert not eventResult.isErr
      let event = !eventResult
      if event.requestId == requestId:
        let slotId = slotId(event.requestId, event.slotIndex)
        filledSlotIds.add slotId

    let filledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    check eventually(
      await client0.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000
    )

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
