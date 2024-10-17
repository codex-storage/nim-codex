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

template eventuallyS*(expression: untyped, timeout=10, step = 5,
    cancelWhenExpression: untyped = false): bool =
  bind Moment, now, seconds

  proc eventuallyS: Future[bool] {.async.} =
    let endTime = Moment.now() + timeout.seconds
    var i = 0
    while not expression:
      inc i
      echo (i*step).seconds
      if endTime < Moment.now():
        return false
      if cancelWhenExpression:
        return false
      await sleepAsync(step.seconds)
    return true

  await eventuallyS()

marketplacesuite "Validation":
  let nodes = 3
  let tolerance = 1
  let proofProbability = 1

  var slotsFilled: seq[SlotId]
  var slotsFreed: seq[SlotId]
  var requestsFailed: seq[RequestId]
  var requestCancelled = false

  var slotFilledSubscription: provider.Subscription
  var requestFailedSubscription: provider.Subscription
  var slotFreedSubscription: provider.Subscription
  var requestCancelledSubscription: provider.Subscription

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
  
  proc trackRequestsFailed(marketplace: Marketplace):
      Future[provider.Subscription] {.async.} =
    requestsFailed = newSeq[RequestId]()
    proc onRequestFailed(event: RequestFailed) =
      requestsFailed.add(event.requestId)
      debug "RequestFailed", requestId = event.requestId

    let subscription = await marketplace.subscribe(RequestFailed, onRequestFailed)
    subscription
  
  proc trackRequestCancelled(marketplace: Marketplace, requestId: RequestId):
      Future[provider.Subscription] {.async.} =
    requestCancelled = false
    proc onRequestCancelled(event: RequestCancelled) =
      if requestId == event.requestId:
        requestCancelled = true
        debug "RequestCancelled", requestId = event.requestId

    let subscription = await marketplace.subscribe(RequestCancelled, onRequestCancelled)
    subscription
  
  proc trackSlotsFreed(marketplace: Marketplace, requestId: RequestId):
      Future[provider.Subscription] {.async.} =
    slotsFreed = newSeq[SlotId]()
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId:
        let slotId = slotId(event.requestId, event.slotIndex)
        slotsFreed.add(slotId)
        debug "SlotFreed", requestId = event.requestId, slotIndex = event.slotIndex,
          slotId = slotId, slotsFreed = slotsFreed.len

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)
    subscription

  proc startTrackingEvents(marketplace: Marketplace, requestId: RequestId) {.async.} =
    slotFilledSubscription = await marketplace.trackSlotsFilled()
    requestFailedSubscription = await marketplace.trackRequestsFailed()
    slotFreedSubscription = await marketplace.trackSlotsFreed(requestId)
    requestCancelledSubscription =
      await marketplace.trackRequestCancelled(requestId)
  
  proc stopTrackingEvents() {.async.} =
    await slotFilledSubscription.unsubscribe()
    await slotFreedSubscription.unsubscribe()
    await requestFailedSubscription.unsubscribe()
    await requestCancelledSubscription.unsubscribe()
  
  proc checkSlotsFailed(marketplace: Marketplace, slotsFilled: seq[SlotId], 
      slotsFreed: seq[SlotId]) {.async.} =
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
        .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("purchases", "onchain")
        .some,

    providers:
      CodexConfigs.init(nodes=1)
        .withSimulateProofFailures(idx=0, failEveryNProofs=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("sales", "onchain")
        .some,

    validators:
      CodexConfigs.init(nodes=2)
        .withValidationGroups(groups = 2)
        .withValidationGroupIndex(idx = 0, groupIndex = 0)
        .withValidationGroupIndex(idx = 1, groupIndex = 1)
        .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("validator") # each topic as a separate string argument
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    # let mine a block to sync the blocktime with the current clock
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

    await marketplace.startTrackingEvents(requestId)

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
    
    # Because of erasure coding, after (tolerance + 1) slots are freed, the
    # remaining nodes are be freed but marked as "Failed" as the whole
    # request fails. A couple of checks to capture this:
    let expectedSlotsFreed = tolerance + 1
    check eventuallyS((slotsFreed.len == expectedSlotsFreed and
        requestsFailed.contains(requestId)),
      timeout = secondsTillRequestEnd + 60, step = 5,
      cancelWhenExpression = requestCancelled)
    
    # extra check
    await marketplace.checkSlotsFailed(slotsFilled, slotsFreed)

    await stopTrackingEvents()

  test "validator uses historical state to mark missing proofs", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        .debug() # uncomment to enable console log output
        .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("purchases", "onchain")
        .some,

    providers:
      CodexConfigs.init(nodes=1)
        .withSimulateProofFailures(idx=0, failEveryNProofs=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("sales", "onchain")
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    # let mine a block to sync the blocktime with the current clock
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

    await marketplace.startTrackingEvents(requestId)

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
    
    # extra block just to make sure we have one that separates us
    # from the block containing the last (past) SlotFilled event
    discard await ethProvider.send("evm_mine")

    var validators = CodexConfigs.init(nodes=2)
      .withValidationGroups(groups = 2)
      .withValidationGroupIndex(idx = 0, groupIndex = 0)
      .withValidationGroupIndex(idx = 1, groupIndex = 1)
      .debug() # uncomment to enable console log output
      .withLogFile() # uncomment to output log file to: # tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      .withLogTopics("validator") # each topic as a separate string argument
    
    failAndTeardownOnError "failed to start validator nodes":
      for config in validators.configs.mitems:
        let node = await startValidatorNode(config)
        running.add RunningNode(
          role: Role.Validator,
          node: node
        )
    
    discard await ethProvider.send("evm_mine")
    currentTime = await ethProvider.currentTime()
    let secondsTillRequestEnd = (requestEndTime - currentTime.truncate(uint64)).int

    debug "validation suite", secondsTillRequestEnd = secondsTillRequestEnd.seconds
    
    # Because of erasure coding, after (tolerance + 1) slots are freed, the
    # remaining nodes are be freed but marked as "Failed" as the whole
    # request fails. A couple of checks to capture this:
    let expectedSlotsFreed = tolerance + 1
    
    check eventuallyS((slotsFreed.len == expectedSlotsFreed and
        requestsFailed.contains(requestId)),
      timeout = secondsTillRequestEnd + 60, step = 5,
      cancelWhenExpression = requestCancelled)
    
    # extra check
    await marketplace.checkSlotsFailed(slotsFilled, slotsFreed)

    await stopTrackingEvents()
