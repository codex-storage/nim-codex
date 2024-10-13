from std/times import inMilliseconds
import pkg/codex/logutils
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./marketplacesuite
import ./nodeconfigs

export logutils

logScope:
  topics = "integration test validation"


marketplacesuite "Validator marks proofs as missed when using validation groups":

  test "slot is freed after too many invalid proofs submitted", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("node", "marketplace", "clock")
        .some,

    providers:
      CodexConfigs.init(nodes=1)
        .withSimulateProofFailures(idx=0, failEveryNProofs=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("marketplace", "sales", "reservations", "node", "clock", "slotsbuilder")
        .some,

    validators:
      CodexConfigs.init(nodes=2)
        .withValidationGroups(groups = 2)
        .withValidationGroupIndex(idx = 0, groupIndex = 0)
        .withValidationGroupIndex(idx = 1, groupIndex = 1)
        .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("validator", "integration")
        # .withLogTopics("validator", "integration", "ethers", "clock")
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    let data = await RandomChunker.example(blocks=8)
    createAvailabilities(data.len * 2, duration) # TODO: better value for data.len

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=3,
      tolerance=1,
      proofProbability=1
    )
    let requestId = client0.requestId(purchaseId).get

    check eventually(client0.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000)

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId:
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    check eventually(slotWasFreed, timeout=(duration - expiry).int * 1000)

    await subscription.unsubscribe()
