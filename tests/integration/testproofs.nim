from std/times import inMilliseconds
import pkg/codex/logutils
import pkg/stew/byteutils
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./marketplacesuite
import ./nodeconfigs

export logutils

logScope:
  topics = "integration test proofs"


marketplacesuite "Hosts submit regular proofs":

  test "hosts submit periodic proofs for slots they fill", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("node")
        .some,

    providers:
      CodexConfigs.init(nodes=5)
        .debug(idx=0) # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("marketplace", "sales", "reservations", "node", "clock")
        .some,
  ):
    let client0 = clients()[0].client
    let totalPeriods = 50
    let datasetSizeInBlocks = 8

    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # dataset size = 8 block, with 5 nodes, the slot size = 4 blocks, give each
    # node enough availability to fill one slot only
    createAvailabilities((DefaultBlockSize * 4.NBytes).Natural, totalPeriods.periods)

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=totalPeriods.periods,
      expiry=30.periods,
      nodes=5,
      tolerance=2,
      origDatasetSizeInBlocks = datasetSizeInBlocks)
    check eventually(client0.purchaseStateIs(purchaseId, "started"), timeout=totalPeriods.periods.int * 1000)

    var proofWasSubmitted = false
    proc onProofSubmitted(event: ProofSubmitted) =
      proofWasSubmitted = true

    let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)

    let currentPeriod = await getCurrentPeriod()
    check eventuallyP(proofWasSubmitted, currentPeriod + totalPeriods.u256 + 1)

    await subscription.unsubscribe()


marketplacesuite "Simulate invalid proofs":

  # TODO: these are very loose tests in that they are not testing EXACTLY how
  # proofs were marked as missed by the validator. These tests should be
  # tightened so that they are showing, as an integration test, that specific
  # proofs are being marked as missed by the validator.

  test "slot is freed after too many invalid proofs submitted", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("node")
        .some,

    providers:
      CodexConfigs.init(nodes=5)
        .withSimulateProofFailures(idx=0, failEveryNProofs=1)
        # .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("marketplace", "sales", "reservations", "node")
        .some,

    validators:
      CodexConfigs.init(nodes=1)
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .debug() # uncomment to enable console log output
        .withLogTopics("validator", "onchain", "ethers")
        .some
  ):
    let client0 = clients()[0].client
    let totalPeriods = 50

    let datasetSizeInBlocks = 8
    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # dataset size = 8 block, with 5 nodes, the slot size = 4 blocks, give each
    # node enough availability to fill one slot only
    createAvailabilities((DefaultBlockSize * 4.NBytes).Natural, totalPeriods.periods)

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=totalPeriods.periods,
      expiry=30.periods,
      nodes=5,
      tolerance=1,
      origDatasetSizeInBlocks=datasetSizeInBlocks)
    let requestId = client0.requestId(purchaseId).get

    check eventually client0.purchaseStateIs(purchaseId, "started")

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId and
        event.slotIndex == 0.u256: # assume only one slot, so index 0
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    let currentPeriod = await getCurrentPeriod()
    check eventuallyP(slotWasFreed, currentPeriod + totalPeriods.u256 + 1)

    await subscription.unsubscribe()

  test "slot is not freed when not enough invalid proofs submitted", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat: HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("node")
        .some,

    providers:
      CodexConfigs.init(nodes=5)
        .withSimulateProofFailures(idx=0, failEveryNProofs=3)
        # .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("marketplace", "sales", "reservations", "node")
        .some,

    validators:
      CodexConfigs.init(nodes=1)
        # .debug()
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("validator", "onchain", "ethers")
        .some
  ):
    let client0 = clients()[0].client
    let totalPeriods = 25

    let datasetSizeInBlocks = 8
    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # dataset size = 8 block, with 5 nodes, the slot size = 4 blocks, give each
    # node enough availability to fill one slot only
    createAvailabilities((DefaultBlockSize * 4.NBytes).Natural, totalPeriods.periods)

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=totalPeriods.periods,
      expiry=30.periods,
      nodes=5,
      tolerance=1,
      origDatasetSizeInBlocks=datasetSizeInBlocks)
    let requestId = client0.requestId(purchaseId).get

    check eventually client0.purchaseStateIs(purchaseId, "started")

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId and
          event.slotIndex == 0.u256:
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # check not freed
    let currentPeriod = await getCurrentPeriod()
    check not eventuallyP(slotWasFreed, currentPeriod + totalPeriods.u256 + 1)

    await subscription.unsubscribe()

  test "host that submits invalid proofs is paid out less", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    # hardhat: HardhatConfig().withLogFile(),
    hardhat: HardhatConfig.none,
    clients:
      CodexConfigs.init(nodes=1)
        .debug() # uncomment to enable console log output.debug()
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("node", "erasure", "clock", "purchases", "slotsbuilder")
        .some,

    providers:
      CodexConfigs.init(nodes=5)
        .withSimulateProofFailures(idx=0, failEveryNProofs=2)
        .debug(idx=0) # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("marketplace", "sales", "reservations", "node", "slotsbuilder")
        .some,

    validators:
      CodexConfigs.init(nodes=1)
        # .debug()
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("validator")
        .some
  ):
    let client0 = clients()[0].client
    let providers = providers()
    let totalPeriods = 25

    let datasetSizeInBlocks = 8
    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # original data = 3 blocks so slot size will be 4 blocks
    let slotSize = (DefaultBlockSize * 4.NBytes).Natural.u256

    discard providers[0].client.postAvailability(
      size=slotSize, # should match 1 slot only
      duration=totalPeriods.periods.u256,
      minPrice=300.u256,
      maxCollateral=200.u256
    )

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=totalPeriods.periods,
      expiry=10.periods,
      nodes=5,
      tolerance=1,
      origDatasetSizeInBlocks=datasetSizeInBlocks
    )

    without requestId =? client0.requestId(purchaseId):
      fail()

    var filledSlotIds: seq[SlotId] = @[]
    proc onSlotFilled(event: SlotFilled) =
      let slotId = slotId(event.requestId, event.slotIndex)
      filledSlotIds.add slotId

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # wait til first slot is filled
    check eventually filledSlotIds.len > 0

    template waitForSlotFilled(provider: CodexProcess, idx: int) =
      discard provider.client.postAvailability(
        size=slotSize, # should match 1 slot only
        duration=totalPeriods.periods.u256,
        minPrice=300.u256,
        maxCollateral=200.u256
      )

      check eventually filledSlotIds.len > idx

    # TODO: becausee we now have 5+ slots to fill plus proof generation, this
    # may take way too long. Another idea is to update the SlotFilled contract
    # event to include the host that filled the slot. With that, we can use
    # `onSlotFilled` to build a provider > slotIdx table in memory and use that
    # to check sale states
    for i in 1..<providers.len:
      # now add availability for remaining providers, which should allow them to
      # to put the remaining slots in their queues. They need to fill slots
      # one-by-one so we can track their slot idx/ids
      let provider = providers[i]
      provider.waitForSlotFilled(i)


    # Wait til remaining providers are in the Proving state.
    for i in 1..<providers.len:
      check eventually providers[i].client.saleStateIs(filledSlotIds[i], "SaleProving")

    # contract should now be started
    check eventually client0.purchaseStateIs(purchaseId, "started")

    # all providers should now be able to reach the SalePayout state once the
    # contract has finishe
    let currentPeriod = await getCurrentPeriod()
    for i in 0..<providers.len:
      check eventuallyP(
        # SaleFinished happens too quickly, check SalePayout instead
        providers[i].client.saleStateIs(filledSlotIds[i], "SalePayout"),
        currentPeriod + totalPeriods.u256 + 1)

    check eventually(
      (await token.balanceOf(providers[1].ethAccount)) >
      (await token.balanceOf(providers[0].ethAccount))
    )

    await subscription.unsubscribe()
