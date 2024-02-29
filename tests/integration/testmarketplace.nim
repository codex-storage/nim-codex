import pkg/stew/byteutils
import pkg/codex/units
import ./marketplacesuite
import ./nodeconfigs
import ../examples

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
    let duration = 10.periods
    let collateral = 200.u256
    let expiry = 5.periods
    let datasetSizeInBlocks = 8
    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
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
      size=(data.len div 2).u256,
      duration=duration.u256,
      minPrice=reward,
      maxCollateral=collateral)

    let cid = clientApi.upload(data).get

    var slotIdxFilled = none UInt256
    proc onSlotFilled(event: SlotFilled) =
      slotIdxFilled = some event.slotIndex

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # client requests storage but requires five slots to host the content
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

    # wait until sale is cancelled
    without requestId =? clientApi.requestId(id):
      fail()
    let slotId = slotId(requestId, !slotIdxFilled)
    check eventually(providerApi.saleStateIs(slotId, "SaleCancelled"), timeout=expiry.int * 1000)

    check eventually (
      let endBalanceProvider = (await token.balanceOf(provider.ethAccount));
      let difference = endBalanceProvider - startBalanceProvider;
      difference > 0 and
      difference < expiry.u256*reward
    )
    check eventually (
      let endBalanceClient = (await token.balanceOf(client.ethAccount));
      let endBalanceProvider = (await token.balanceOf(provider.ethAccount));
      (startBalanceClient - endBalanceClient) == (endBalanceProvider - startBalanceProvider)
    )

    await subscription.unsubscribe()
