import std/times
import ../../examples
import ../../contracts/time
import ../../contracts/deployment
import ./../marketplacesuite except Subscription
import ../twonodes except Subscription
import ../nodeconfigs
from pkg/ethers import Subscription

marketplacesuite(name = "Marketplace"):
  let marketplaceConfig = NodeConfigs(
    clients: CodexConfigs.init(nodes = 1).some,
    providers: CodexConfigs.init(nodes = 1).some,
  )

  var host: CodexClient
  var hostAccount: Address
  var client: CodexClient
  var clientAccount: Address

  const minPricePerBytePerSecond = 1.u256
  const collateralPerByte = 1.u256
  const blocks = 8
  const ecNodes = 3
  const ecTolerance = 1
  const size = 0xFFFFFF.uint64
  const slotBytes = slotSize(blocks, ecNodes, ecTolerance)
  const duration = 20 * 60.uint64
  const expiry = 10 * 60.uint64
  const pricePerSlotPerSecond = minPricePerBytePerSecond * slotBytes

  setup:
    host = providers()[0].client
    hostAccount = providers()[0].ethAccount
    client = clients()[0].client
    clientAccount = clients()[0].ethAccount

    # Our Hardhat configuration does use automine, which means that time tracked by `ethProvider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests ethProvider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await ethProvider.advanceTime(1.u256)

  test "nodes negotiate contracts on the marketplace",
    marketplaceConfig, stopOnRequestFail = true:
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
    let (purchaseId, requestId) = await requestStorage(client)

    await waitForRequestToStart(requestId, expiry.int64)

    let purchase = (await client.getPurchase(purchaseId)).get
    check purchase.error == none string

    let state = await marketplace.requestState(requestId)
    check state == RequestState.Started

    let availabilities = (await host.getAvailabilities()).get
    check availabilities.len == 1

    let newSize = availabilities[0].freeSize
    let datasetSize = datasetSize(blocks, ecNodes, ecTolerance)
    check newSize > 0 and newSize.u256 + datasetSize == size.u256

    let reservations = (await host.getAvailabilityReservations(availability.id)).get
    check reservations.len == 3
    check reservations[0].requestId == purchase.requestId

    let signer = ethProvider.getSigner(hostAccount)
    let marketplaceWithProviderSigner = marketplace.connect(signer)
    let slots = await marketplaceWithProviderSigner.mySlots()
    check slots.len == 3

    for slotId in slots:
      let slot = await marketplaceWithProviderSigner.getActiveSlot(slotId)
      check slot.request.id == purchase.requestId

  test "node slots gets paid out and rest of tokens are returned to client",
    marketplaceConfig, stopOnRequestFail = true:
    var providerRewardEvent = newAsyncEvent()
    var clientFundsEvent = newAsyncEvent()
    var transferEvent = newAsyncEvent()
    var filledAtPerSlot: seq[UInt256] = @[]
    var requestId: RequestId

    # host makes storage available
    let startBalanceHost = await token.balanceOf(hostAccount)
    let startBalanceClient = await token.balanceOf(clientAccount)

    proc storeFilledAtTimestamps() {.async.} =
      let filledAt = await ethProvider.blockTime(BlockTag.latest)
      filledAtPerSlot.add(filledAt)

    proc onSlotFilled(eventResult: ?!SlotFilled) {.raises: [].} =
      assert not eventResult.isErr
      let event = !eventResult
      asyncSpawn storeFilledAtTimestamps()

    proc checkProviderRewards() {.async.} =
      let endBalanceHost = await token.balanceOf(hostAccount)
      let requestEnd = await marketplace.requestEnd(requestId)
      let rewards = filledAtPerSlot
        .mapIt((requestEnd.u256 - it) * pricePerSlotPerSecond)
        .foldl(a + b, 0.u256)

      if rewards + startBalanceHost == endBalanceHost:
        providerRewardEvent.fire()

    proc checkClientFunds() {.async.} =
      let requestEnd = await marketplace.requestEnd(requestId)
      let hostRewards = filledAtPerSlot
        .mapIt((requestEnd.u256 - it) * pricePerSlotPerSecond)
        .foldl(a + b, 0.u256)

      let requestPrice = pricePerSlotPerSecond * duration.u256 * 3
      let fundsBackToClient = requestPrice - hostRewards
      let endBalanceClient = await token.balanceOf(clientAccount)

      if startBalanceClient + fundsBackToClient - requestPrice == endBalanceClient:
        clientFundsEvent.fire()

    proc onTransfer(eventResult: ?!Transfer) =
      assert not eventResult.isErr

      let data = eventResult.get()
      if data.receiver == hostAccount:
        asyncSpawn checkProviderRewards()
      if data.receiver == clientAccount:
        asyncSpawn checkClientFunds()

    discard (
      await host.postAvailability(
        totalSize = size,
        duration = duration,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = size.u256 * minPricePerBytePerSecond,
      )
    ).get

    # client requests storage
    let (_, id) = await requestStorage(client)
    requestId = id

    # Subscribe SlotFilled event to receive the filledAt timestamp
    # and calculate the provider reward
    await marketplaceSubscribe(SlotFilled, onSlotFilled)

    await waitForRequestToStart(requestId, expiry.int64)

    # Proving mechanism uses blockchain clock to do proving/collect/cleanup round
    # hence we must use `advanceTime` over `sleepAsync` as Hardhat does mine new blocks
    # only with new transaction
    await ethProvider.advanceTime(duration.u256)

    await tokenSubscribe(onTransfer)

    # Wait for the exact expected balances. 
    # The timeout is 60 seconds because the event should occur quickly,
    # thanks to `advanceTime` moving to the end of the request duration.
    await clientFundsEvent.wait().wait(timeout = chronos.seconds(60))
    await providerRewardEvent.wait().wait(timeout = chronos.seconds(60))

  test "SP are able to process slots after workers were busy with other slots and ignored them",
    NodeConfigs(
      clients: CodexConfigs.init(nodes = 1)
      # .debug()
      .some,
      providers: CodexConfigs.init(nodes = 2)
      # .debug()
      # .withLogFile()
      # .withLogTopics("marketplace", "sales", "statemachine","slotqueue", "reservations")
      .some,
    ),
    stopOnRequestFail = true:
    var requestId: RequestId

    # We create an avavilability allowing the first SP to host the 3 slots.
    # So the second SP will not have any availability so it will just process
    # the slots and ignore them.
    discard await host.postAvailability(
      totalSize = 3 * slotBytes.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotBytes * minPricePerBytePerSecond,
    )

    let (_, id) = await requestStorage(client)
    requestId = id

    # We wait that the 3 slots are filled by the first SP
    await waitForRequestToStart(requestId, expiry.int64)

    # Here we create the same availability as previously but for the second SP.
    # Meaning that, after ignoring all the slots for the first request, the second SP will process
    # and host the slots for the second request.
    let host1 = providers()[1].client

    discard await host1.postAvailability(
      totalSize = 3 * slotBytes.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotBytes * collateralPerByte,
    )

    let (_, id2) = await requestStorage(client)
    requestId = id2

    # Wait that the slots of the second request are filled
    await waitForRequestToStart(requestId, expiry.int64)

    # Double check, verify that our second SP hosts the 3 slots
    let host1Account = providers()[1].ethAccount
    let signer = ethProvider.getSigner(host1Account)
    let marketplaceWithProviderSigner = marketplace.connect(signer)
    let slots = await marketplaceWithProviderSigner.mySlots()
    check slots.len == 3

    for slotId in slots:
      let slot = await marketplaceWithProviderSigner.getActiveSlot(slotId)
      check slot.request.id == requestId

marketplacesuite(name = "Marketplace payouts"):
  const minPricePerBytePerSecond = 1.u256
  const collateralPerByte = 1.u256
  const blocks = 8
  const ecNodes = 3
  const ecTolerance = 1
  const slotBytes = slotSize(blocks, ecNodes, ecTolerance)
  const duration = 20 * 60.uint64
  const expiry = 10 * 60.uint64
  const pricePerSlotPerSecond = minPricePerBytePerSecond * slotBytes

  test "expired request partially pays out for stored time",
    NodeConfigs(
      # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
      hardhat: HardhatConfig.none,
      clients: CodexConfigs.init(nodes = 1)
      #  .debug() # uncomment to enable console log output.debug()
      # .withLogFile()
      # # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      # .withLogTopics("node", "erasure")
      .some,
      providers: CodexConfigs.init(nodes = 1)
      #  .debug() # uncomment to enable console log output
      # .withLogFile()
      # # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      # .withLogTopics(
      #   "node", "marketplace", "sales", "reservations", "node", "statemachine"
      # )
      .some,
    ),
    stopOnRequestFail = true:
    let client = clients()[0]
    let provider = providers()[0]
    let clientApi = client.client
    let providerApi = provider.client
    let hostAccount = providers()[0].ethAccount
    let clientAccount = clients()[0].ethAccount

    var slotIndex = 0.uint64
    var slotFilledEvent = newAsyncEvent()
    var requestCancelledEvent = newAsyncEvent()
    var providerRewardEvent = newAsyncEvent()
    var filledAtPerSlot: seq[UInt256] = @[]
    var requestId: RequestId

    let startBalanceClient = await token.balanceOf(client.ethAccount)
    let startBalanceProvider = await token.balanceOf(hostAccount)

    proc storeFilledAtTimestamps() {.async.} =
      let filledAt = await ethProvider.blockTime(BlockTag.latest)
      filledAtPerSlot.add(filledAt)

    proc onSlotFilled(eventResult: ?!SlotFilled) {.raises: [].} =
      assert not eventResult.isErr
      let event = !eventResult
      slotIndex = event.slotIndex
      asyncSpawn storeFilledAtTimestamps()
      slotFilledEvent.fire()

    proc onRequestCancelled(eventResult: ?!RequestCancelled) =
      assert not eventResult.isErr
      requestCancelledEvent.fire()

    proc checkProviderRewards() {.async.} =
      let endBalanceProvider = await token.balanceOf(hostAccount)
      let requestEnd = await marketplace.requestEnd(requestId)
      let rewards = filledAtPerSlot
        .mapIt((requestEnd.u256 - it) * pricePerSlotPerSecond)
        .foldl(a + b, 0.u256)

      if rewards + startBalanceProvider == endBalanceProvider:
        providerRewardEvent.fire()

    proc onTransfer(eventResult: ?!Transfer) =
      assert not eventResult.isErr

      let data = eventResult.get()
      if data.receiver == hostAccount:
        asyncSpawn checkProviderRewards()

    # provider makes storage available
    let datasetSize = datasetSize(blocks, ecNodes, ecTolerance)
    let totalAvailabilitySize = (datasetSize div 2).truncate(uint64)

    discard await providerApi.postAvailability(
      # make availability size small enough that we can't fill all the slots,
      # thus causing a cancellation
      totalSize = totalAvailabilitySize,
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = collateralPerByte * totalAvailabilitySize.u256,
    )

    let (_, id) = await requestStorage(clientApi)
    requestId = id

    await marketplaceSubscribe(SlotFilled, onSlotFilled)
    await marketplaceSubscribe(RequestCancelled, onRequestCancelled)

    # wait until one slot is filled
    await slotFilledEvent.wait().wait(timeout = chronos.seconds(expiry.int))
    let slotId = slotId(requestId, slotIndex)

    await tokenSubscribe(onTransfer)

    # wait until sale is cancelled
    await ethProvider.advanceTime(expiry.u256)
    await requestCancelledEvent.wait().wait(timeout = chronos.seconds(5))
    await advanceToNextPeriod()

    # Wait for the expected balance for the provider
    await providerRewardEvent.wait().wait(timeout = chronos.seconds(60))

    # Ensure that total rewards stay within the payout limit 
    # determined by the expiry date.
    let requestEnd = await marketplace.requestEnd(requestId)
    let rewards = filledAtPerSlot
      .mapIt((requestEnd.u256 - it) * pricePerSlotPerSecond)
      .foldl(a + b, 0.u256)
    check expiry.u256 * pricePerSlotPerSecond >= rewards

    let endBalanceProvider = (await token.balanceOf(provider.ethAccount))
    let endBalanceClient = (await token.balanceOf(client.ethAccount))

    check(
      startBalanceClient - endBalanceClient == endBalanceProvider - startBalanceProvider
    )

  test "the collateral is returned after a sale is ignored",
    NodeConfigs(
      hardhat: HardhatConfig.none,
      clients: CodexConfigs.init(nodes = 1).some,
      providers: CodexConfigs.init(nodes = 3)
      # .debug()
      # uncomment to enable console log output
      # .withLogFile()
      # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      # .withLogTopics(
      #   "node", "marketplace", "sales", "reservations", "statemachine"
      # )
      .some,
    ),
    stopOnRequestFail = true:
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let provider2 = providers()[2]

    # Here we create 3 SP which can host 3 slot.
    # While they will process the slot, each SP will
    # create a reservation for each slot.
    # Likely we will have 1 slot by SP and the other reservations
    # will be ignored. In that case, the collateral assigned for
    # the reservation should return to the availability.
    discard await provider0.client.postAvailability(
      totalSize = 3 * slotBytes.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotBytes * minPricePerBytePerSecond,
    )
    discard await provider1.client.postAvailability(
      totalSize = 3 * slotBytes.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotBytes * minPricePerBytePerSecond,
    )
    discard await provider2.client.postAvailability(
      totalSize = 3 * slotBytes.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotBytes * minPricePerBytePerSecond,
    )

    let (_, requestId) = await requestStorage(client0.client)
    await waitForRequestToStart(requestId, expiry.int64)

    # Here we will check that for each provider, the total remaining collateral
    # will match the available slots.
    # So if a SP hosts 1 slot, it should have enough total remaining collateral
    # to host 2 more slots.
    for provider in providers():
      let client = provider.client
      check eventually(
        block:
          try:
            let availabilities = (await client.getAvailabilities()).get
            let availability = availabilities[0]
            let slots = (await client.getSlots()).get
            let availableSlots = (3 - slots.len).u256

            availability.totalRemainingCollateral ==
              availableSlots * slotBytes * minPricePerBytePerSecond
          except HttpConnectionError:
            return false,
        timeout = 30 * 1000,
      )
