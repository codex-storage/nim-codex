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
        .withLogTopics("node, marketplace")
        .some,

    providers:
      CodexConfigs.init(nodes=5)
        .debug(idx=0) # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("marketplace", "sales", "reservations", "node", "clock")
        .some,
  ):
    let client0 = clients()[0].client
    let duration = 50.periods
    let expiry = 30.periods
    let datasetSizeInBlocks = 8

    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # dataset size = 8 block, with 5 nodes, the slot size = 4 blocks, give each
    # node enough availability to fill one slot only
    let slotSize = DefaultBlockSize.int * 4

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=duration,
      expiry=expiry,
      nodes=5,
      tolerance=2,
      origDatasetSizeInBlocks = datasetSizeInBlocks)

    discard await waitForAllSlotsFilled(slotSize, duration)

    # contract should now be started
    check eventually(
      client0.purchaseStateIs(purchaseId, "started"),
      timeout=expiry.int * 1000)

    var proofWasSubmitted = false
    proc onProofSubmitted(event: ProofSubmitted) =
      proofWasSubmitted = true

    let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)

    check eventually(proofWasSubmitted, timeout=duration.int*1000)

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
        .withLogTopics("node, marketplace")
        .some,

    providers:
      CodexConfigs.init(nodes=5)
        .debug(idx=0) # uncomment to enable console log output
        .withSimulateProofFailures(idx=4, failEveryNProofs=1)
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("marketplace", "sales", "reservations", "node", "clock", "slotsbuilder")
        .some,

    validators:
      CodexConfigs.init(nodes=1)
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .debug() # uncomment to enable console log output
        .withLogTopics("validator", "onchain", "ethers")
        .some
  ):
    let client0 = clients()[0].client
    let duration = 50.periods
    let expiry = 30.periods
    let datasetSizeInBlocks = 8

    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # dataset size = 8 block, with 5 nodes, the slot size = 4 blocks, give each
    # node enough availability to fill one slot only
    let slotSize = DefaultBlockSize.int * 4

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=duration,
      expiry=expiry,
      proofProbability=1,
      nodes=5,
      tolerance=2,
      origDatasetSizeInBlocks = datasetSizeInBlocks)

    discard await waitForAllSlotsFilled(slotSize, duration)

    # contract should now be started
    check eventually(
      client0.purchaseStateIs(purchaseId, "started"),
      timeout=expiry.int * 1000)

    startIntervalMining(1000)
    changePeriodAdvancementTo(6000)
    # await switchToIntervalMining(intervalMillis=5000)

    let requestId = client0.requestId(purchaseId).get
    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId and
        event.slotIndex == 4.u256: # assume only one slot, so index 0
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # let currentPeriod = await getCurrentPeriod()
    # check eventuallyP(slotWasFreed, currentPeriod + totalPeriods.u256 + 1)
    check eventually(slotWasFreed, timeout=duration.int*1000)

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
        .withSimulateProofFailures(idx=4, failEveryNProofs=3)
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
    let duration = 25.periods
    let expiry = 10.periods

    let datasetSizeInBlocks = 8
    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # dataset size = 8 block, with 5 nodes, the slot size = 4 blocks, give each
    # node enough availability to fill one slot only
    let slotSize = DefaultBlockSize.int * 4

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=duration,
      expiry=expiry,
      proofProbability=1,
      nodes=5,
      tolerance=2,
      origDatasetSizeInBlocks=datasetSizeInBlocks)

    let requestId = client0.requestId(purchaseId).get

    discard await waitForAllSlotsFilled(slotSize, duration)

    check eventually client0.purchaseStateIs(purchaseId, "started")

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId and
          event.slotIndex == 4.u256:
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # check not freed
    check not eventually(slotWasFreed, timeout=duration.int*1000)

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
    let duration = 25.periods
    let expiry = 10.periods

    let datasetSizeInBlocks = 8
    let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # dataset size = 8 block, with 5 nodes, the slot size = 4 blocks, give each
    # node enough availability to fill one slot only
    let slotSize = DefaultBlockSize.int * 4

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=duration,
      expiry=expiry,
      nodes=5,
      tolerance=2,
      origDatasetSizeInBlocks=datasetSizeInBlocks
    )

    without requestId =? client0.requestId(purchaseId):
      fail()

    discard await waitForAllSlotsFilled(slotSize, duration)
    # contract should now be started
    check eventually client0.purchaseStateIs(purchaseId, "started")

    check eventually(client0.purchaseStateIs(purchaseId, "finished"),
      timeout=duration.int*1000)

    check eventually(
      (await token.balanceOf(providers[1].ethAccount)) >
      (await token.balanceOf(providers[0].ethAccount))
    )
