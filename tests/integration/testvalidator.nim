from std/times import inMilliseconds, initDuration, inSeconds, fromUnix
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

    check eventually(client0.purchaseStateIs(purchaseId, "started"), 
      timeout = expiry.int * 1000)

    var validators = CodexConfigs.init(nodes=2)
      .withValidationGroups(groups = 2)
      .withValidationGroupIndex(idx = 0, groupIndex = 0)
      .withValidationGroupIndex(idx = 1, groupIndex = 1)
      .debug() # uncomment to enable console log output
      # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      .withLogTopics("validator") # each topic as a separate string argument
    
    failAndTeardownOnError "failed to start validator nodes":
      for config in validators.configs.mitems:
        let node = await startValidatorNode(config)
        running.add RunningNode(
          role: Role.Validator,
          node: node
        )
    
    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId:
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    check eventually(slotWasFreed, timeout=(duration - expiry).int * 1000)

    await subscription.unsubscribe()
  
  test "validator only looks 30 days back for historical state", NodeConfigs(
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
    let duration30days = initDuration(days = 30)
    let duration = expiry + duration30days.inSeconds.uint64 + 10.periods

    let data = await RandomChunker.example(blocks=8)
    createAvailabilities(data.len * 2, duration) # TODO: better value for data.len

    let cid = client0.upload(data).get

    var currentTime = await ethProvider.currentTime()

    let expiryEndTime = currentTime.truncate(uint64) + expiry
    let requestEndTime = currentTime.truncate(uint64) + duration
    debug "test validator: ", currentTime = currentTime.truncate(uint64),
      requestEndTime = requestEndTime, expiryEndTime = expiryEndTime
    debug "test validator: ", currentTime = currentTime.truncate(int64).fromUnix,
      requestEndTime = requestEndTime.int64.fromUnix,
        expiryEndTime = expiryEndTime.int64.fromUnix
    
    proc onSlotFilled(event: SlotFilled) =
      let slotId = slotId(event.requestId, event.slotIndex)
      debug "SlotFilled", requestId = event.requestId, slotIndex = event.slotIndex,
        slotId = slotId

    let subscriptionOnSlotFilled = await marketplace.subscribe(SlotFilled, onSlotFilled)
    
    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=3,
      tolerance=1,
      reward=1.u256,
      proofProbability=1
    )
    let requestId = client0.requestId(purchaseId).get

    check eventually(client0.purchaseStateIs(purchaseId, "started"), 
      timeout = expiry.int * 1000)

    currentTime = await ethProvider.currentTime()
    var waitTime = (expiryEndTime - currentTime.truncate(uint64)).int.seconds
    debug "test validation - waiting till end of expiry", waitTime = waitTime
    await sleepAsync(waitTime)

    discard await ethProvider.send("evm_mine")

    await ethProvider.advanceTimeTo(
      expiryEndTime.u256 + duration30days.inSeconds.u256)
    debug "test validator[after advance]: ", currentTime = currentTime.truncate(SecondsSince1970)
    debug "test validator[after advance]: ", currentTime = 
      currentTime.truncate(SecondsSince1970).fromUnix

    var validators = CodexConfigs.init(nodes=1)
      .debug() # uncomment to enable console log output
      # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      .withLogTopics("validator", "clock", "market") # each topic as a separate string argument
    
    failAndTeardownOnError "failed to start validator nodes":
      for config in validators.configs.mitems:
        let node = await startValidatorNode(config)
        running.add RunningNode(
          role: Role.Validator,
          node: node
        )
    
    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId:
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # check not freed
    currentTime = await ethProvider.currentTime()
    if requestEndTime > currentTime.truncate(uint64):
      waitTime = (requestEndTime - currentTime.truncate(uint64)).int.seconds
      debug "test validation - waiting for request end", waitTime = waitTime
      await sleepAsync(waitTime)
    
    debug "test validation - request ended"

    check not slotWasFreed

    # check eventually(client0.purchaseStateIs(purchaseId, "finished"), 
    #   timeout = 60 * 1000)

    await subscription.unsubscribe()
    await subscriptionOnSlotFilled.unsubscribe()
    debug "test validation - unsubscribed"

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
        .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("validator")
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
