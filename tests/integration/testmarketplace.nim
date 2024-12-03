import pkg/stew/byteutils
import pkg/codex/units
import ../examples
import ../contracts/time
import ../contracts/deployment
import ./marketplacesuite
import ./twonodes
import ./nodeconfigs

twonodessuite "Marketplace", debug1 = false, debug2 = false:
  setup:
    # Our Hardhat configuration does use automine, which means that time tracked by `ethProvider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests ethProvider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await ethProvider.advanceTime(1.u256)

  test "nodes negotiate contracts on the marketplace":
    let size = 0xFFFFFF.u256
    let data = await RandomChunker.example(blocks=8)
    # client 2 makes storage available
    let availability = client2.postAvailability(totalSize=size, duration=20*60.u256, minPrice=300.u256, maxCollateral=300.u256).get

    # client 1 requests storage
    let cid = client1.upload(data).get
    let id = client1.requestStorage(
      cid,
      duration=20*60.u256,
      reward=400.u256,
      proofProbability=3.u256,
      expiry=10*60,
      collateral=200.u256,
      nodes = 3,
      tolerance = 1).get

    check eventually(client1.purchaseStateIs(id, "started"), timeout=10*60*1000)
    let purchase = client1.getPurchase(id).get
    check purchase.error == none string
    let availabilities = client2.getAvailabilities().get
    check availabilities.len == 1
    let newSize = availabilities[0].freeSize
    check newSize > 0 and newSize < size

    let reservations = client2.getAvailabilityReservations(availability.id).get
    check reservations.len == 3
    check reservations[0].requestId == purchase.requestId

  test "node slots gets paid out and rest of tokens are returned to client":
    let size = 0xFFFFFF.u256
    let data = await RandomChunker.example(blocks = 8)
    let marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
    let tokenAddress = await marketplace.token()
    let token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
    let reward = 400.u256
    let duration = 20*60.u256
    let nodes = 3'u

    # client 2 makes storage available
    let startBalanceHost = await token.balanceOf(account2)
    discard client2.postAvailability(totalSize=size, duration=20*60.u256, minPrice=300.u256, maxCollateral=300.u256).get

    # client 1 requests storage
    let cid = client1.upload(data).get
    let id = client1.requestStorage(
      cid,
      duration=duration,
      reward=reward,
      proofProbability=3.u256,
      expiry=10*60,
      collateral=200.u256,
      nodes = nodes,
      tolerance = 1).get

    check eventually(client1.purchaseStateIs(id, "started"), timeout=10*60*1000)
    let purchase = client1.getPurchase(id).get
    check purchase.error == none string

    let clientBalanceBeforeFinished = await token.balanceOf(account1)

    # Proving mechanism uses blockchain clock to do proving/collect/cleanup round
    # hence we must use `advanceTime` over `sleepAsync` as Hardhat does mine new blocks
    # only with new transaction
    await ethProvider.advanceTime(duration)

    # Checking that the hosting node received reward for at least the time between <expiry;end>
    check eventually (await token.balanceOf(account2)) - startBalanceHost >= (duration-5*60)*reward*nodes.u256

    # Checking that client node receives some funds back that were not used for the host nodes
    check eventually(
      (await token.balanceOf(account1)) - clientBalanceBeforeFinished > 0,
      timeout = 10*1000 # give client a bit of time to withdraw its funds
    )

marketplacesuite "Marketplace payouts":

  test "expired request partially pays out for stored time",
    NodeConfigs(
      # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
      hardhat: HardhatConfig.none,

      clients:
        CodexConfigs.init(nodes=1)
          # .debug() # uncomment to enable console log output.debug()
          # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
          # .withLogTopics("node", "erasure")
          .some,

      providers:
        CodexConfigs.init(nodes=1)
          # .debug() # uncomment to enable console log output
          # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
          # .withLogTopics("node", "marketplace", "sales", "reservations", "node", "proving", "clock")
          .some,
  ):
    let reward = 400.u256
    let duration = 20.periods
    let collateral = 200.u256
    let expiry = 10.periods
    let data = await RandomChunker.example(blocks=8)
    let client = clients()[0]
    let provider = providers()[0]
    let clientApi = client.client
    let providerApi = provider.client
    let startBalanceProvider = await token.balanceOf(provider.ethAccount)
    let startBalanceClient = await token.balanceOf(client.ethAccount)

    # provider makes storage available
    discard providerApi.postAvailability(
      # make availability size small enough that we can't fill all the slots,
      # thus causing a cancellation
      totalSize=(data.len div 2).u256,
      duration=duration.u256,
      minPrice=reward,
      maxCollateral=collateral)

    let cid = clientApi.upload(data).get

    var slotIdxFilled = none UInt256
    proc onSlotFilled(eventResult: ?!SlotFilled) =
      assert not eventResult.isErr
      slotIdxFilled = some (!eventResult).slotIndex

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # client requests storage but requires multiple slots to host the content
    let id = await clientApi.requestStorage(
      cid,
      duration=duration,
      reward=reward,
      expiry=expiry,
      collateral=collateral,
      nodes=3,
      tolerance=1
    )

    # wait until one slot is filled
    check eventually(slotIdxFilled.isSome, timeout=expiry.int * 1000)
    let slotId = slotId(!clientApi.requestId(id), !slotIdxFilled)

    # wait until sale is cancelled
    await ethProvider.advanceTime(expiry.u256)
    check eventually providerApi.saleStateIs(slotId, "SaleCancelled")

    check eventually (
      let endBalanceProvider = (await token.balanceOf(provider.ethAccount));
      endBalanceProvider > startBalanceProvider and
      endBalanceProvider < startBalanceProvider + expiry.u256*reward
    )
    check eventually(
      (
        let endBalanceClient = (await token.balanceOf(client.ethAccount));
        let endBalanceProvider = (await token.balanceOf(provider.ethAccount));
        (startBalanceClient - endBalanceClient) == (endBalanceProvider - startBalanceProvider)
      ),
      timeout = 10*1000 # give client a bit of time to withdraw its funds
    )

    await subscription.unsubscribe()
