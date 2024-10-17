from std/times import inMilliseconds, initDuration, inSeconds, fromUnix
import std/strformat
import pkg/codex/logutils
import pkg/questionable/results
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./marketplacesuite
import ./nodeconfigs

export logutils

logScope:
  topics = "integration test validation"

template eventuallyS*(expression: untyped, timeout=10, step = 5): bool =
  bind Moment, now, seconds

  proc eventuallyS: Future[bool] {.async.} =
    let endTime = Moment.now() + timeout.seconds
    var i = 0
    while not expression:
      inc i
      echo (i*step).seconds
      if endTime < Moment.now():
        return false
      await sleepAsync(step.seconds)
    return true

  await eventuallyS()

marketplacesuite "Validation":
  let nodes = 3
  let tolerance = 1
  let proofProbability = 1
  when defined(windows):
    let providerUrl = "ws://localhost:8545"
  else:
    let providerUrl = "http://localhost:8545"
  
  test "validator marks proofs as missing when using validation groups", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        .withEthProvider(providerUrl)
        # .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("purchases", "onchain")
        .some,

    providers:
      CodexConfigs.init(nodes=1)
        .withSimulateProofFailures(idx=0, failEveryNProofs=1)
        .withEthProvider(providerUrl)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("sales", "onchain")
        .some,

    validators:
      CodexConfigs.init(nodes=2)
        .withEthProvider(providerUrl)
        .withValidationGroups(groups = 2)
        .withValidationGroupIndex(idx = 0, groupIndex = 0)
        .withValidationGroupIndex(idx = 1, groupIndex = 1)
        # .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("validator") # each topic as a separate string argument
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    echo fmt"{providerUrl = }"

    # for a good start
    discard await ethProvider.send("evm_mine")

    var currentTime = await ethProvider.currentTime()
    let requestEndTime = currentTime.truncate(uint64) + duration

    let data = await RandomChunker.example(blocks=8)
    
    # TODO: better value for data.len below. This TODO is also present in
    # testproofs.nim - we may want to address it or remove the comment.
    createAvailabilities(data.len * 2, duration)

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=nodes,
      tolerance=tolerance,
      proofProbability=proofProbability
    )
    let requestId = client0.requestId(purchaseId).get

    debug "validation suite", purchaseId = purchaseId.toHex, requestId = requestId

    echo fmt"expiry = {(expiry + 60).int.seconds}"

    check eventuallyS(client0.purchaseStateIs(purchaseId, "started"),
      timeout = (expiry + 60).int, step = 5)
    
    # if purchase state is not "started", it does not make sense to continue
    without purchaseState =? client0.getPurchase(purchaseId).?state:
      fail()
    
    debug "validation suite", purchaseState = purchaseState
    echo fmt"{purchaseState = }"

    if purchaseState != "started":
      fail()

    discard await ethProvider.send("evm_mine")
    
    currentTime = await ethProvider.currentTime()
    let secondsTillRequestEnd = (requestEndTime - currentTime.truncate(uint64)).int

    debug "validation suite", secondsTillRequestEnd = secondsTillRequestEnd.seconds
    
    # Because of Erasure Coding, the expected number of slots being freed
    # is tolerance + 1. When more than tolerance slots are freed, the whole
    # request will fail. Thus, awaiting for a failing state should
    # be sufficient to conclude that validators did their job correctly.
    # NOTICE: We actually have to wait for the "errored" state, because
    # immediately after withdrawing the funds the purchasing state machine
    # transitions to the "errored" state.
    check eventuallyS(client0.purchaseStateIs(purchaseId, "errored"), 
      timeout = secondsTillRequestEnd + 60, step = 5)
  
  test "validator uses historical state to mark missing proofs", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        .withEthProvider(providerUrl)
        # .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("purchases", "onchain")
        .some,

    providers:
      CodexConfigs.init(nodes=1)
        .withEthProvider(providerUrl)
        .withSimulateProofFailures(idx=0, failEveryNProofs=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("sales", "onchain")
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    echo fmt"{providerUrl = }"

    # for a good start
    discard await ethProvider.send("evm_mine")

    var currentTime = await ethProvider.currentTime()
    let requestEndTime = currentTime.truncate(uint64) + duration

    let data = await RandomChunker.example(blocks=8)

    # TODO: better value for data.len below. This TODO is also present in
    # testproofs.nim - we may want to address it or remove the comment.
    createAvailabilities(data.len * 2, duration)

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=nodes,
      tolerance=tolerance,
      proofProbability=proofProbability
    )
    let requestId = client0.requestId(purchaseId).get

    debug "validation suite", purchaseId = purchaseId.toHex, requestId = requestId

    echo fmt"expiry = {(expiry + 60).int.seconds}"    

    check eventuallyS(client0.purchaseStateIs(purchaseId, "started"), 
      timeout = (expiry + 60).int, step = 5)

    # if purchase state is not "started", it does not make sense to continue
    without purchaseState =? client0.getPurchase(purchaseId).?state:
      fail()
    
    debug "validation suite", purchaseState = purchaseState
    echo fmt"{purchaseState = }"

    if purchaseState != "started":
      fail()
    
    # just to make sure we have a mined block that separates us
    # from the block containing the last SlotFilled event
    discard await ethProvider.send("evm_mine")

    var validators = CodexConfigs.init(nodes=2)
      .withEthProvider(providerUrl)
      .withValidationGroups(groups = 2)
      .withValidationGroupIndex(idx = 0, groupIndex = 0)
      .withValidationGroupIndex(idx = 1, groupIndex = 1)
      # .debug() # uncomment to enable console log output
      .withLogFile() # uncomment to output log file to: # tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      .withLogTopics("validator") # each topic as a separate string argument
    
    failAndTeardownOnError "failed to start validator nodes":
      for config in validators.configs.mitems:
        let node = await startValidatorNode(config)
        running.add RunningNode(
          role: Role.Validator,
          node: node
        )
    
    currentTime = await ethProvider.currentTime()
    let secondsTillRequestEnd = (requestEndTime - currentTime.truncate(uint64)).int

    debug "validation suite", secondsTillRequestEnd = secondsTillRequestEnd.seconds
    
    # Because of Erasure Coding, the expected number of slots being freed
    # is tolerance + 1. When more than tolerance slots are freed, the whole
    # request will fail. Thus, awaiting for a failing state should
    # be sufficient to conclude that validators did their job correctly.
    # NOTICE: We actually have to wait for the "errored" state, because
    # immediately after withdrawing the funds the purchasing state machine
    # transitions to the "errored" state.
    check eventuallyS(client0.purchaseStateIs(purchaseId, "errored"),
      timeout = secondsTillRequestEnd + 60, step = 5)
