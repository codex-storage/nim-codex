from std/times import inMilliseconds, initDuration, inSeconds, fromUnix
import std/sets
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

marketplacesuite "Validaton":
  let nodes = 3
  let tolerance = 1
  var slotsFilled: seq[SlotId]
  var slotsFreed: seq[SlotId]

  proc trackSlotsFilled(marketplace: Marketplace):
      Future[provider.Subscription] {.async.} =
    slotsFilled = newSeq[SlotId]()
    proc onSlotFilled(event: SlotFilled) =
      let slotId = slotId(event.requestId, event.slotIndex)
      slotsFilled.add(slotId)
      debug "SlotFilled", requestId = event.requestId, slotIndex = event.slotIndex,
        slotId = slotId

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)
    subscription
  
  proc trackSlotsFreed(requestId: RequestId, marketplace: Marketplace):
      Future[provider.Subscription] {.async.} =
    slotsFreed = newSeq[SlotId]()
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId:
        let slotId = slotId(event.requestId, event.slotIndex)
        slotsFreed.add(slotId)
        debug "onSlotFreed", requestId = requestId, slotIndex = event.slotIndex,
          slotId = slotId, slotsFreed = slotsFreed.len

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)
    subscription

  proc checkSlotsFailed(slotsFilled: seq[SlotId], 
      slotsFreed: seq[SlotId], marketplace: Marketplace) {.async.} =
    let slotsNotFreed = slotsFilled.filter(
      slotId => not slotsFreed.contains(slotId)
    ).toHashSet
    var slotsFailed = initHashSet[SlotId]()
    for slotId in slotsFilled:
      let state = await marketplace.slotState(slotId)
      if state == SlotState.Failed:
        slotsFailed.incl(slotId)
    
    debug "slots failed", slotsFailed = slotsFailed, slotsNotFreed = slotsNotFreed
    check slotsNotFreed == slotsFailed
  
  test "validator marks proofs as missing when using validation groups", NodeConfigs(
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
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("validator")
        # .withLogTopics("validator", "integration", "ethers", "clock")
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    let data = await RandomChunker.example(blocks=8)
    
    # TODO: better value for data.len below. This TODO is also present in
    # testproofs.nim - we may want to address it or remove the comment.
    createAvailabilities(data.len * 2, duration)

    let slotFilledSubscription = await trackSlotsFilled(marketplace)

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=nodes,
      tolerance=tolerance,
      proofProbability=1
    )
    let requestId = client0.requestId(purchaseId).get

    check eventually(client0.purchaseStateIs(purchaseId, "started"),
      timeout = expiry.int * 1000)
    
    let slotFreedSubscription = 
      await trackSlotsFreed(requestId, marketplace)

    let expectedSlotsFreed = nodes - tolerance
    check eventually((slotsFreed.len == expectedSlotsFreed),
      timeout=(duration - expiry).int * 1000)
    
    # Because of erasure coding, if e.g. 2 out of 3 nodes are freed, the last
    # node will not be freed but marked as "Failed" because the whole request
    # will fail. For this reason we need an extra check:
    await checkSlotsFailed(slotsFilled, slotsFreed, marketplace)
    
    await slotFilledSubscription.unsubscribe()
    await slotFreedSubscription.unsubscribe()
  
  test "validator uses historical state to mark missing proofs", NodeConfigs(
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
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    let data = await RandomChunker.example(blocks=8)

    # TODO: better value for data.len below. This TODO is also present in
    # testproofs.nim - we may want to address it or remove the comment.
    createAvailabilities(data.len * 2, duration)

    let slotFilledSubscription = await trackSlotsFilled(marketplace)

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=nodes,
      tolerance=tolerance,
      proofProbability=1
    )
    let requestId = client0.requestId(purchaseId).get

    check eventually(client0.purchaseStateIs(purchaseId, "started"), 
      timeout = expiry.int * 1000)
    
    # just to make sure we have a mined block that separates us
    # from the block containing the last SlotFilled event
    discard await ethProvider.send("evm_mine")

    var validators = CodexConfigs.init(nodes=2)
      .withValidationGroups(groups = 2)
      .withValidationGroupIndex(idx = 0, groupIndex = 0)
      .withValidationGroupIndex(idx = 1, groupIndex = 1)
      # .debug() # uncomment to enable console log output
      # .withLogFile() # uncomment to output log file to:
      # tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      # .withLogTopics("validator") # each topic as a separate string argument
    
    failAndTeardownOnError "failed to start validator nodes":
      for config in validators.configs.mitems:
        let node = await startValidatorNode(config)
        running.add RunningNode(
          role: Role.Validator,
          node: node
        )
    
    let slotFreedSubscription = 
      await trackSlotsFreed(requestId, marketplace)

    let expectedSlotsFreed = nodes - tolerance
    check eventually((slotsFreed.len == expectedSlotsFreed),
      timeout=(duration - expiry).int * 1000)
    
    # Because of erasure coding, if e.g. 2 out of 3 nodes are freed, the last
    # node will not be freed but marked as "Failed" because the whole request
    # will fail. For this reason we need an extra check:
    await checkSlotsFailed(slotsFilled, slotsFreed, marketplace)
    
    await slotFilledSubscription.unsubscribe()
    await slotFreedSubscription.unsubscribe()
