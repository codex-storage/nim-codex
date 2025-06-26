import std/times
import std/httpclient
import ../examples
import ../contracts/time
import ../contracts/deployment
import ./marketplacesuite
import ./twonodes
import ./nodeconfigs

marketplacesuite(name = "Marketplace", stopOnRequestFail = true):
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

  setup:
    host = providers()[0].client
    hostAccount = providers()[0].ethAccount
    client = clients()[0].client
    clientAccount = clients()[0].ethAccount

    # Our Hardhat configuration does use automine, which means that time tracked by `ethProvider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests ethProvider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await ethProvider.advanceTime(1.u256)

  test "nodes negotiate contracts on the marketplace", marketplaceConfig:
    let size = 0xFFFFFF.uint64
    let data = await RandomChunker.example(blocks = blocks)
    # host makes storage available
    let availability = (
      await host.postAvailability(
        totalSize = size,
        duration = 20 * 60.uint64,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = size.u256 * minPricePerBytePerSecond,
      )
    ).get

    # client requests storage
    let cid = (await client.upload(data)).get
    let id = await client.requestStorage(
      cid,
      duration = 20 * 60.uint64,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 3.u256,
      expiry = 10 * 60.uint64,
      collateralPerByte = collateralPerByte,
      nodes = ecNodes,
      tolerance = ecTolerance,
    )

    discard await waitForRequestToStart()

    let purchase = (await client.getPurchase(id)).get
    check purchase.error == none string
    let availabilities = (await host.getAvailabilities()).get
    check availabilities.len == 1
    let newSize = availabilities[0].freeSize
    check newSize > 0 and newSize < size

    let reservations = (await host.getAvailabilityReservations(availability.id)).get
    check reservations.len == 3
    check reservations[0].requestId == purchase.requestId

  test "node slots gets paid out and rest of tokens are returned to client",
    marketplaceConfig:
    let size = 0xFFFFFF.uint64
    let data = await RandomChunker.example(blocks = blocks)
    let marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
    let tokenAddress = await marketplace.token()
    let token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
    let duration = 20 * 60.uint64

    # host makes storage available
    let startBalanceHost = await token.balanceOf(hostAccount)
    discard (
      await host.postAvailability(
        totalSize = size,
        duration = 20 * 60.uint64,
        minPricePerBytePerSecond = minPricePerBytePerSecond,
        totalCollateral = size.u256 * minPricePerBytePerSecond,
      )
    ).get

    # client requests storage
    let cid = (await client.upload(data)).get
    let id = await client.requestStorage(
      cid,
      duration = duration,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 3.u256,
      expiry = 10 * 60.uint64,
      collateralPerByte = collateralPerByte,
      nodes = ecNodes,
      tolerance = ecTolerance,
    )

    discard await waitForRequestToStart()

    var counter = 0
    var transferEvent = newAsyncEvent()
    proc onTransfer(eventResult: ?!Transfer) =
      assert not eventResult.isErr
      counter += 1
      if counter == 6:
        transferEvent.fire()

    let tokenSubscription = await token.subscribe(Transfer, onTransfer)

    let purchase = (await client.getPurchase(id)).get
    check purchase.error == none string

    let clientBalanceBeforeFinished = await token.balanceOf(clientAccount)

    # Proving mechanism uses blockchain clock to do proving/collect/cleanup round
    # hence we must use `advanceTime` over `sleepAsync` as Hardhat does mine new blocks
    # only with new transaction
    await ethProvider.advanceTime(duration.u256)

    await transferEvent.wait().wait(timeout = chronos.seconds(60))

    # Checking that the hosting node received reward for at least the time between <expiry;end>
    let slotSize = slotSize(blocks, ecNodes, ecTolerance)
    let pricePerSlotPerSecond = minPricePerBytePerSecond * slotSize
    check (await token.balanceOf(hostAccount)) - startBalanceHost >=
      (duration - 5 * 60).u256 * pricePerSlotPerSecond * ecNodes.u256

    # Checking that client node receives some funds back that were not used for the host nodes
    check ((await token.balanceOf(clientAccount)) - clientBalanceBeforeFinished > 0)

    await tokenSubscription.unsubscribe()

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
    ):
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let duration = 20 * 60.uint64

    let data = await RandomChunker.example(blocks = blocks)
    let slotSize = slotSize(blocks, ecNodes, ecTolerance)

    # We create an avavilability allowing the first SP to host the 3 slots.
    # So the second SP will not have any availability so it will just process
    # the slots and ignore them.
    discard await provider0.client.postAvailability(
      totalSize = 3 * slotSize.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotSize * minPricePerBytePerSecond,
    )

    let cid = (await client0.client.upload(data)).get

    let purchaseId = await client0.client.requestStorage(
      cid,
      duration = duration,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 1.u256,
      expiry = 10 * 60.uint64,
      collateralPerByte = collateralPerByte,
      nodes = ecNodes,
      tolerance = ecTolerance,
    )

    let requestId = (await client0.client.requestId(purchaseId)).get

    # We wait that the 3 slots are filled by the first SP
    discard await waitForRequestToStart()

    # Here we create the same availability as previously but for the second SP.
    # Meaning that, after ignoring all the slots for the first request, the second SP will process
    # and host the slots for the second request.
    discard await provider1.client.postAvailability(
      totalSize = 3 * slotSize.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotSize * collateralPerByte,
    )

    let purchaseId2 = await client0.client.requestStorage(
      cid,
      duration = duration,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 3.u256,
      expiry = 10 * 60.uint64,
      collateralPerByte = collateralPerByte,
      nodes = ecNodes,
      tolerance = ecTolerance,
    )
    let requestId2 = (await client0.client.requestId(purchaseId2)).get

    # Wait that the slots of the second request are filled
    discard await waitForRequestToStart()

    # Double check, verify that our second SP hosts the 3 slots
    check ((await provider1.client.getSlots()).get).len == 3

marketplacesuite(name = "Marketplace payouts", stopOnRequestFail = true):
  const minPricePerBytePerSecond = 1.u256
  const collateralPerByte = 1.u256
  const blocks = 8
  const ecNodes = 3
  const ecTolerance = 1

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
    ):
    let duration = 20.periods
    let expiry = 10.periods
    let data = await RandomChunker.example(blocks = blocks)
    let client = clients()[0]
    let provider = providers()[0]
    let clientApi = client.client
    let providerApi = provider.client
    let startBalanceProvider = await token.balanceOf(provider.ethAccount)
    let startBalanceClient = await token.balanceOf(client.ethAccount)

    # provider makes storage available
    let datasetSize = datasetSize(blocks, ecNodes, ecTolerance)
    let totalAvailabilitySize = (datasetSize div 2).truncate(uint64)
    discard await providerApi.postAvailability(
      # make availability size small enough that we can't fill all the slots,
      # thus causing a cancellation
      totalSize = totalAvailabilitySize,
      duration = duration.uint64,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = collateralPerByte * totalAvailabilitySize.u256,
    )

    let cid = (await clientApi.upload(data)).get

    var slotIdxFilled = none uint64
    proc onSlotFilled(eventResult: ?!SlotFilled) =
      assert not eventResult.isErr
      slotIdxFilled = some (!eventResult).slotIndex

    let slotFilledSubscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    var requestCancelledEvent = newAsyncEvent()
    proc onRequestCancelled(eventResult: ?!RequestCancelled) =
      assert not eventResult.isErr
      requestCancelledEvent.fire()

    let requestCancelledSubscription =
      await marketplace.subscribe(RequestCancelled, onRequestCancelled)

    # client requests storage but requires multiple slots to host the content
    let id = await clientApi.requestStorage(
      cid,
      duration = duration,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      expiry = expiry,
      collateralPerByte = collateralPerByte,
      nodes = ecNodes,
      tolerance = ecTolerance,
    )

    # wait until one slot is filled
    check eventually(slotIdxFilled.isSome, timeout = expiry.int * 1000)
    let slotId = slotId(!(await clientApi.requestId(id)), !slotIdxFilled)

    var counter = 0
    var transferEvent = newAsyncEvent()
    proc onTransfer(eventResult: ?!Transfer) =
      assert not eventResult.isErr
      counter += 1
      if counter == 3:
        transferEvent.fire()

    let tokenAddress = await marketplace.token()
    let token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
    let tokenSubscription = await token.subscribe(Transfer, onTransfer)

    # wait until sale is cancelled
    await ethProvider.advanceTime(expiry.u256)

    await requestCancelledEvent.wait().wait(timeout = chronos.seconds(5))

    await advanceToNextPeriod()

    await transferEvent.wait().wait(timeout = chronos.seconds(60))

    let slotSize = slotSize(blocks, ecNodes, ecTolerance)
    let pricePerSlotPerSecond = minPricePerBytePerSecond * slotSize

    check (
      let endBalanceProvider = (await token.balanceOf(provider.ethAccount))
      endBalanceProvider > startBalanceProvider and
        endBalanceProvider < startBalanceProvider + expiry.u256 * pricePerSlotPerSecond
    )
    check (
      (
        let endBalanceClient = (await token.balanceOf(client.ethAccount))
        let endBalanceProvider = (await token.balanceOf(provider.ethAccount))
        (startBalanceClient - endBalanceClient) ==
          (endBalanceProvider - startBalanceProvider)
      )
    )

    await slotFilledSubscription.unsubscribe()
    await requestCancelledSubscription.unsubscribe()
    await tokenSubscription.unsubscribe()

  test "the collateral is returned after a sale is ignored",
    NodeConfigs(
      hardhat: HardhatConfig.none,
      clients: CodexConfigs.init(nodes = 1).some,
      providers: CodexConfigs.init(nodes = 3)
      # .debug()
      # uncomment to enable console log output
      # .withLogFile()
      # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      # .withLogTopics("node", "marketplace", "sales", "reservations", "statemachine")
      .some,
    ):
    let data = await RandomChunker.example(blocks = blocks)
    let client0 = clients()[0]
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let provider2 = providers()[2]
    let duration = 20 * 60.uint64
    let slotSize = slotSize(blocks, ecNodes, ecTolerance)

    # Here we create 3 SP which can host 3 slot.
    # While they will process the slot, each SP will
    # create a reservation for each slot.
    # Likely we will have 1 slot by SP and the other reservations
    # will be ignored. In that case, the collateral assigned for
    # the reservation should return to the availability.
    discard await provider0.client.postAvailability(
      totalSize = 3 * slotSize.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotSize * minPricePerBytePerSecond,
    )
    discard await provider1.client.postAvailability(
      totalSize = 3 * slotSize.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotSize * minPricePerBytePerSecond,
    )
    discard await provider2.client.postAvailability(
      totalSize = 3 * slotSize.truncate(uint64),
      duration = duration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = 3 * slotSize * minPricePerBytePerSecond,
    )

    let cid = (await client0.client.upload(data)).get

    let purchaseId = await client0.client.requestStorage(
      cid,
      duration = duration,
      pricePerBytePerSecond = minPricePerBytePerSecond,
      proofProbability = 1.u256,
      expiry = 10 * 60.uint64,
      collateralPerByte = collateralPerByte,
      nodes = ecNodes,
      tolerance = ecTolerance,
    )

    let requestId = (await client0.client.requestId(purchaseId)).get

    discard await waitForRequestToStart()

    # Here we will check that for each provider, the total remaining collateral
    # will match the available slots.
    # So if a SP hosts 1 slot, it should have enough total remaining collateral
    # to host 2 more slots.
    for provider in providers():
      let client = provider.client
      check eventually(
        block:
          let availabilities = (await client.getAvailabilities()).get
          let availability = availabilities[0]
          let slots = (await client.getSlots()).get
          let availableSlots = (3 - slots.len).u256

          availability.totalRemainingCollateral ==
            availableSlots * slotSize * minPricePerBytePerSecond,
        timeout = 30 * 1000,
      )
