import std/math
import pkg/stew/byteutils
import ./marketplacesuite
import ../examples

marketplacesuite "Marketplace payouts":

  test "expired request partially pays out for stored time",
    NodeConfigs(
      # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
      # hardhat: HardhatConfig().withLogFile()

      clients:
        CodexConfig()
          .nodes(1)
          # .debug() # uncomment to enable console log output.debug()
          .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
          .withLogTopics("node", "erasure"),

      providers:
        CodexConfig()
          .nodes(1)
          # .debug() # uncomment to enable console log output
          .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
          .withLogTopics("marketplace", "sales", "reservations", "node", "proving", "clock"),
  ):
    let reward = 400.u256
    let duration = 100.periods
    let collateral = 200.u256
    let expiry = 4.periods
    let data = byteutils.toHex(await exampleData())
    let slotSize = (data.len / 2).ceil.int.u256
    let client = clients()[0]
    let provider = providers()[0]
    let clientApi = client.client
    let providerApi = provider.client
    let startBalanceProvider = await token.balanceOf(provider.ethAccount)
    let startBalanceClient = await token.balanceOf(client.ethAccount)

    # provider makes storage available
    discard providerApi.postAvailability(
      size=slotSize, # large enough to only fill 1 slot, thus causing a cancellation
      duration=duration.u256,
      minPrice=reward,
      maxCollateral=collateral)

    let cid = clientApi.upload(data).get

    var slotIdxFilled = none UInt256
    proc onSlotFilled(event: SlotFilled) =
      slotIdxFilled = some event.slotIndex

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # client requests storage but requires two nodes to host the content
    let id = await clientApi.requestStorage(
      cid,
      duration=duration,
      reward=reward,
      expiry=expiry,
      collateral=collateral,
      nodes=2
    )

    # wait until one slot is filled
    check eventually slotIdxFilled.isSome

    # wait until sale is cancelled
    without requestId =? clientApi.requestId(id):
      fail()
    let slotId = slotId(requestId, !slotIdxFilled)
    check eventually(providerApi.saleStateIs(slotId, "SaleCancelled"))

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
