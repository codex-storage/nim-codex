from std/times import inMilliseconds, initDuration, inSeconds, fromUnix
import std/sequtils
import std/sugar
import pkg/codex/logutils
import pkg/questionable/results
import pkg/ethers/provider
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./marketplacesuite
import ./nodeconfigs

export logutils

logScope:
  topics = "integration test validation"

template eventuallyS(expression: untyped, timeout=10, step = 5,
    cancelExpression: untyped = false): bool =
  bind Moment, now, seconds

  proc eventuallyS: Future[bool] {.async.} =
    let endTime = Moment.now() + timeout.seconds
    var i = 0
    var secondsElapsed = 0
    while not expression:
      inc i
      secondsElapsed = i*step
      # echo secondsElapsed.seconds
      if secondsElapsed mod 180 == 0:
        await stopTrackingEvents()
        await marketplace.startTrackingEvents()
      if endTime < Moment.now():
        return false
      if cancelExpression:
        return false
      await sleepAsync(step.seconds)
    return true

  await eventuallyS()

marketplacesuiteWithProviderUrl "Validation", "http://127.0.0.1:8545":
  let nodes = 3
  let tolerance = 1
  let proofProbability = 1

  var events = {
    $SlotFilled: newSeq[ref MarketplaceEvent](),
    $SlotFreed: newSeq[ref MarketplaceEvent](),
    $RequestFailed: newSeq[ref MarketplaceEvent](),
    $RequestCancelled: newSeq[ref MarketplaceEvent]()
  }.toTable
  var eventSubscriptions = newSeq[provider.Subscription]()

  proc box[T](x: T): ref T =
    new(result);
    result[] = x

  proc onMarketplaceEvent[T: MarketplaceEvent](event: T) {.gcsafe, raises:[].} =
    try:
      debug "onMarketplaceEvent", eventType = $T, event = event
      events[$T].add(box(event))
    except KeyError:
      discard

  proc startTrackingEvents(marketplace: Marketplace) {.async.} =
    eventSubscriptions.add(
      await marketplace.subscribe(SlotFilled, onMarketplaceEvent[SlotFilled])
    )
    eventSubscriptions.add(
      await marketplace.subscribe(RequestFailed, onMarketplaceEvent[RequestFailed])
    )
    eventSubscriptions.add(
      await marketplace.subscribe(SlotFreed, onMarketplaceEvent[SlotFreed])
    )
    eventSubscriptions.add(
      await marketplace.subscribe(RequestCancelled, onMarketplaceEvent[RequestCancelled])
    )
  
  proc stopTrackingEvents() {.async.} =
    for event in eventSubscriptions:
      await event.unsubscribe()
  
  proc checkSlotsFreed(requestId: RequestId, expectedSlotsFreed: int): bool =
    events[$SlotFreed].filter(
      e => (ref SlotFreed)(e).requestId == requestId)
        .len == expectedSlotsFreed and
      events[$RequestFailed].map(
        e => (ref RequestFailed)(e).requestId).contains(requestId)
  
  proc isRequestCancelled(requestId: RequestId): bool =
    events[$RequestCancelled].map(e => (ref RequestCancelled)(e).requestId)
      .contains(requestId)
  
  proc getSlots[T: MarketplaceEvent](requestId: RequestId): seq[SlotId] =
    events[$T].filter(
      e => (ref T)(e).requestId == requestId).map(
        e => slotId((ref T)(e).requestId, (ref T)(e).slotIndex))
  
  proc checkSlotsFailed(marketplace: Marketplace, requestId: RequestId) {.async.} =
    let slotsFreed = getSlots[SlotFreed](requestId)
    let slotsFilled = getSlots[SlotFilled](requestId)
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
        # .debug() # uncomment to enable console log output
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

    await marketplace.startTrackingEvents()

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

    check eventuallyS(client0.purchaseStateIs(purchaseId, "started"),
      timeout = (expiry + 60).int, step = 5)
    
    # if purchase state is not "started", it does not make sense to continue
    without purchaseState =? client0.getPurchase(purchaseId).?state:
      fail()
      return
    
    debug "validation suite", purchaseState = purchaseState 

    if purchaseState != "started":
      fail()
      return

    discard await ethProvider.send("evm_mine")
    currentTime = await ethProvider.currentTime()
    let secondsTillRequestEnd = (requestEndTime - currentTime.truncate(uint64)).int

    debug "validation suite", secondsTillRequestEnd = secondsTillRequestEnd.seconds
    
    # Because of erasure coding, after (tolerance + 1) slots are freed, the
    # remaining nodes are be freed but marked as "Failed" as the whole
    # request fails. A couple of checks to capture this:
    let expectedSlotsFreed = tolerance + 1
    check eventuallyS(checkSlotsFreed(requestId, expectedSlotsFreed),
      timeout = secondsTillRequestEnd + 60, step = 5,
      cancelExpression = isRequestCancelled(requestId))
    
    # extra check
    await marketplace.checkSlotsFailed(requestId)

    await stopTrackingEvents()

  test "validator uses historical state to mark missing proofs", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
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

    await marketplace.startTrackingEvents()

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

    check eventuallyS(client0.purchaseStateIs(purchaseId, "started"), 
      timeout = (expiry + 60).int, step = 5)

    # if purchase state is not "started", it does not make sense to continue
    without purchaseState =? client0.getPurchase(purchaseId).?state:
      fail()
      return
    
    debug "validation suite", purchaseState = purchaseState

    if purchaseState != "started":
      fail()
      return
    
    # extra block just to make sure we have one that separates us
    # from the block containing the last (past) SlotFilled event
    discard await ethProvider.send("evm_mine")

    var validators = CodexConfigs.init(nodes=2)
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
    
    discard await ethProvider.send("evm_mine")
    currentTime = await ethProvider.currentTime()
    let secondsTillRequestEnd = (requestEndTime - currentTime.truncate(uint64)).int

    debug "validation suite", secondsTillRequestEnd = secondsTillRequestEnd.seconds
    
    # Because of erasure coding, after (tolerance + 1) slots are freed, the
    # remaining nodes are be freed but marked as "Failed" as the whole
    # request fails. A couple of checks to capture this:
    let expectedSlotsFreed = tolerance + 1
    
    check eventuallyS(checkSlotsFreed(requestId, expectedSlotsFreed),
      timeout = secondsTillRequestEnd + 60, step = 5,
      cancelExpression = isRequestCancelled(requestId))
    
    # extra check
    await marketplace.checkSlotsFailed(requestId)

    await stopTrackingEvents()
