import std/times
import std/httpclient
import ../examples
import ../contracts/time
import ../contracts/deployment
import ./marketplacesuite
import ./twonodes
import ./nodeconfigs

marketplacesuite "Marketplace":
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

    check eventually(
      await client.purchaseStateIs(id, "started"), timeout = 10 * 60 * 1000
    )
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

    check eventually(
      await client.purchaseStateIs(id, "started"), timeout = 10 * 60 * 1000
    )
    let purchase = (await client.getPurchase(id)).get
    check purchase.error == none string

    let clientBalanceBeforeFinished = await token.balanceOf(clientAccount)

    # Proving mechanism uses blockchain clock to do proving/collect/cleanup round
    # hence we must use `advanceTime` over `sleepAsync` as Hardhat does mine new blocks
    # only with new transaction
    await ethProvider.advanceTime(duration.u256)

    # Checking that the hosting node received reward for at least the time between <expiry;end>
    let slotSize = slotSize(blocks, ecNodes, ecTolerance)
    let pricePerSlotPerSecond = minPricePerBytePerSecond * slotSize
    check eventually (await token.balanceOf(hostAccount)) - startBalanceHost >=
      (duration - 5 * 60).u256 * pricePerSlotPerSecond * ecNodes.u256

    # Checking that client node receives some funds back that were not used for the host nodes
    check eventually(
      (await token.balanceOf(clientAccount)) - clientBalanceBeforeFinished > 0,
      timeout = 10 * 1000, # give client a bit of time to withdraw its funds
    )

marketplacesuite "Marketplace payouts":
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
      # .debug() # uncomment to enable console log output.debug()
      # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      # .withLogTopics("node", "erasure")
      .some,
      providers: CodexConfigs.init(nodes = 1)
      # .debug() # uncomment to enable console log output
      # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      # .withLogTopics("node", "marketplace", "sales", "reservations", "node", "proving", "clock")
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

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

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

    # wait until sale is cancelled
    await ethProvider.advanceTime(expiry.u256)
    check eventually await providerApi.saleStateIs(slotId, "SaleCancelled")

    await advanceToNextPeriod()

    let slotSize = slotSize(blocks, ecNodes, ecTolerance)
    let pricePerSlotPerSecond = minPricePerBytePerSecond * slotSize

    check eventually (
      let endBalanceProvider = (await token.balanceOf(provider.ethAccount))
      endBalanceProvider > startBalanceProvider and
        endBalanceProvider < startBalanceProvider + expiry.u256 * pricePerSlotPerSecond
    )
    check eventually(
      (
        let endBalanceClient = (await token.balanceOf(client.ethAccount))
        let endBalanceProvider = (await token.balanceOf(provider.ethAccount))
        (startBalanceClient - endBalanceClient) ==
          (endBalanceProvider - startBalanceProvider)
      ),
      timeout = 10 * 1000, # give client a bit of time to withdraw its funds
    )

    await subscription.unsubscribe()
