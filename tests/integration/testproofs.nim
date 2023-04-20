import std/sequtils
import std/os
from std/times import getTime, toUnix
import pkg/chronicles
import codex/contracts/marketplace
import codex/contracts/deployment
import codex/periods
import ../contracts/time
import ../codex/helpers/eventually
import ./twonodes
import ./multinodes

logScope:
  topics = "test proofs"

twonodessuite "Proving integration test", debug1=false, debug2=false:

  let validatorDir = getTempDir() / "CodexValidator"

  var marketplace: Marketplace
  var period: uint64

  setup:
    let deployment = Deployment.init()
    marketplace = Marketplace.new(!deployment.address(Marketplace), provider)
    period = (await marketplace.config()).proofs.period.truncate(uint64)

    # Our Hardhat configuration does use automine, which means that time tracked by `provider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests provider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await provider.advanceTime(1.u256)

  proc waitUntilPurchaseIsStarted(proofProbability: uint64 = 3,
                                  duration: uint64 = 100 * period,
                                  expiry: uint64 = 30) {.async.} =
    discard client2.postAvailability(
      size=0xFFFFF,
      duration=duration,
      minPrice=300,
      maxCollateral=200
    )
    let cid = client1.upload("some file contents")
    let expiry = (await provider.currentTime()) + expiry.u256
    let purchase = client1.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      proofProbability=proofProbability,
      collateral=100,
      reward=400
    )
    check eventually client1.getPurchase(purchase){"state"} == %"started"

  proc advanceToNextPeriod {.async.} =
    let periodicity = Periodicity(seconds: period.u256)
    let currentPeriod = periodicity.periodOf(await provider.currentTime())
    let endOfPeriod = periodicity.periodEnd(currentPeriod)
    await provider.advanceTimeTo(endOfPeriod + 1)

  proc startValidator: NodeProcess =
    startNode([
      "--data-dir=" & validatorDir,
      "--api-port=8089",
      "--disc-port=8099",
      "--validator",
      "--eth-account=" & $accounts[2]
    ], debug = false)

  proc stopValidator(node: NodeProcess) =
    node.stop()
    removeDir(validatorDir)

  test "hosts submit periodic proofs for slots they fill":
    await waitUntilPurchaseIsStarted(proofProbability=1)
    var proofWasSubmitted = false
    proc onProofSubmitted(event: ProofSubmitted) =
      proofWasSubmitted = true
    let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)
    await provider.advanceTime(period.u256)
    check eventually proofWasSubmitted
    await subscription.unsubscribe()

  test "validator will mark proofs as missing":
    let validator = startValidator()
    await waitUntilPurchaseIsStarted(proofProbability=1)

    node2.stop()

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      slotWasFreed = true
    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    for _ in 0..<100:
      if slotWasFreed:
        break
      else:
        await advanceToNextPeriod()
        await sleepAsync(1.seconds)

    check slotWasFreed

    await subscription.unsubscribe()
    stopValidator(validator)

multinodesuite "Simulate invalid proofs",
  StartNodes.init(clients=1'u, providers=0'u, validators=1'u),
  DebugNodes.init(client=false, provider=false, validator=false):

  var marketplace: Marketplace
  var period: uint64
  var proofSubmitted: Future[void]
  var subscription: Subscription
  var submitted: seq[seq[byte]]
  var missed: UInt256
  var slotId: SlotId
  var validator: NodeProcess
  let validatorDir = getTempDir() / "CodexValidator"
  var periodDowntime: uint8
  var downtime: seq[(Period, bool)]
  var periodicity: Periodicity

  setup:
    let deployment = Deployment.init()
    marketplace = Marketplace.new(!deployment.address(Marketplace), provider)
    let config = await marketplace.config()
    period = config.proofs.period.truncate(uint64)
    periodDowntime = config.proofs.downtime
    proofSubmitted = newFuture[void]("proofSubmitted")
    proc onProofSubmitted(event: ProofSubmitted) =
      submitted.add(event.proof)
      proofSubmitted.complete()
      proofSubmitted = newFuture[void]("proofSubmitted")
    subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)
    missed = 0.u256
    slotId = SlotId(array[32, byte].default) # ensure we aren't reusing from prev test
    downtime = @[]
    periodicity = Periodicity(seconds: period.u256)

    # Our Hardhat configuration does use automine, which means that time tracked by `provider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests provider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await provider.advanceTime(1.u256)

  teardown:
    await subscription.unsubscribe()

  proc getCurrentPeriod(): Future[Period] {.async.} =
    return periodicity.periodOf(await provider.currentTime())

  proc waitUntilPurchaseIsStarted(proofProbability: uint64 = 1,
                                  duration: uint64 = 12 * period,
                                  expiry: uint64 = 4 * period,
                                  failEveryNProofs: uint): Future[Period] {.async.} =

    if clients().len < 1 or providers().len < 1:
      raiseAssert("must start at least one client and one provider")

    let client = clients()[0].restClient
    let storageProvider = providers()[0].restClient

    # The last period is the period in which the slot is freed, and therefore
    # proofs cannot be submitted. That means that the duration must go an
    # additional period longer to allow for invalid proofs to be submitted in
    # the second to last period and counted as missed in the last period.
    let dur = duration + (1 * period)

    discard storageProvider.postAvailability(
      size=0xFFFFF,
      duration=dur,
      minPrice=300
    )
    let cid = client.upload("some file contents " & $ getTime().toUnix)
    let expiry = (await provider.currentTime()) + expiry.u256
    let purchase = client.requestStorage(
      cid,
      expiry=expiry,
      duration=dur,
      proofProbability=proofProbability,
      reward=400
    )
    check eventually client.getPurchase(purchase){"state"} == %"started"
    debug "purchase state", state = client.getPurchase(purchase){"state"}
    let requestId = RequestId.fromHex client.getPurchase(purchase){"requestId"}.getStr
    slotId = slotId(requestId, 0.u256)
    return await getCurrentPeriod()

  proc inDowntime: Future[bool] {.async.} =
    var periodPointer = await marketplace.getPointer(slotId)
    return periodPointer < periodDowntime

  proc advanceToNextPeriod {.async.} =
    let periodicity = Periodicity(seconds: period.u256)
    let currentPeriod = periodicity.periodOf(await provider.currentTime())
    let endOfPeriod = periodicity.periodEnd(currentPeriod)
    await provider.advanceTimeTo(endOfPeriod + 1)

  proc advanceToNextPeriodStart {.async.} =
    let currentPeriod = await getCurrentPeriod()
    let startOfPeriod = periodicity.periodEnd(currentPeriod + 1)
    await provider.advanceTimeTo(startOfPeriod)


  proc advanceToCurrentPeriodEnd {.async.} =
    let currentPeriod = await getCurrentPeriod()
    let endOfPeriod = periodicity.periodEnd(currentPeriod)
    await provider.advanceTimeTo(endOfPeriod)

  proc recordDowntime() {.async.} =
    let currentPeriod = await getCurrentPeriod()
    let isInDowntime = await inDowntime()
    downtime.add (currentPeriod, isInDowntime)
    debug "downtime recorded", currentPeriod, isInDowntime

  proc waitUntilSlotNoLongerFilled() {.async.} =
    var i = 0
    # await recordDowntime()
    # await advanceToNextPeriodStart()
    while (await marketplace.slotState(slotId)) == SlotState.Filled:
      let currentPeriod = await getCurrentPeriod()
      # await advanceToCurrentPeriodEnd()
      await advanceToNextPeriod()
      debug "--------------- PERIOD START ---------------", currentPeriod
      await recordDowntime()
      # debug "--------------- PERIOD END ---------------", currentPeriod
      await sleepAsync(1.seconds) # let validation happen
      debug "Checked previous period for missed proofs", missedProofs = $(await marketplace.missingProofs(slotId))
      i += 1
    # downtime.del downtime.len - 1 # remove last downtime as it is an additional proving round adding to duration for checking proofs, and we are offset by one as we are checking previous periods
    missed = await marketplace.missingProofs(slotId)
    debug "Total missed proofs", missed

  proc expectedInvalid(startPeriod: Period,
                       failEveryNProofs: uint,
                       periods: Positive): seq[(Period, bool)] =
    # Create a seq of bools where each bool represents a proving round.
    # If true, an invalid proof should have been sent.
    var p = startPeriod + 1.u256
    var invalid: seq[(Period, bool)] = @[]
    if failEveryNProofs == 0:
      for i in 0..<periods:
        p += 1.u256
        invalid.add (p, false)
      return invalid

    for j in 0..<(periods div failEveryNProofs.int):
      for i in 0..<failEveryNProofs - 1'u:
        p += 1.u256
        invalid.add (p, false)
      p += 1.u256
      invalid.add (p, true)
    # add remaining falses
    for k in 0..<(periods mod failEveryNProofs.int):
      p += 1.u256
      invalid.add (p, false)
    # var proofs = false.repeat(failEveryNProofs - 1)
    # proofs.add true
    # proofs = proofs.cycle(periods div failEveryNProofs.int)
    #                .concat(false.repeat(periods mod failEveryNProofs.int)) # leftover falses
    # return proofs
    return invalid

  proc expectedMissed(startPeriod: Period, failEveryNProofs: uint, periods: Positive): int =
    # Intersects a seq of expected invalid proofs (true = invalid proof) with
    # a seq of bools indicating a period was in pointer downtime (true = period
    # was in pointer downtime).
    # We can only expect an invalid proof to have been submitted if the slot
    # was accepting proofs in that period, meaning it cannot be in downtime.
    # eg failEveryNProofs = 3, periods = 2, the invalid proofs seq will be:
    # @[false, false, true, false, false, true]
    # If we hit downtime in the second half of running our test, the
    # downtime seq might be @[false, false, false, true, true, true]
    # When these two are intersected such that invalid is true and downtime is false,
    # the result would be @[false, false, false, false, false, true], or 1 total
    # invalid proof that should be marked as missed.
    let invalid = expectedInvalid(startPeriod, failEveryNProofs, periods)
    var expectedMissed = 0
    for i in 0..<invalid.len:
      let (invalidPeriod, isInvalidProof) = invalid[i]
      for j in 0..<downtime.len:
        let (downtimePeriod, isDowntime) = downtime[j]
        if invalidPeriod == downtimePeriod:
          if isInvalidProof and not isDowntime:
            inc expectedMissed
          break
      # if invalid[i] == true and downtime[i] == false:
      #   expectedMissed += 1

    debug "expectedMissed invalid / downtime", invalid, downtime, expectedMissed
    return expectedMissed

  test "simulates invalid proof for every proofs":
    let failEveryNProofs = 1'u
    let totalProofs = 12
    startProviderNode(failEveryNProofs)

    let startPeriod = await waitUntilPurchaseIsStarted(duration=totalProofs.uint * period,
                                     failEveryNProofs = failEveryNProofs)
    await waitUntilSlotNoLongerFilled()

    check missed.truncate(int) == expectedMissed(startPeriod, failEveryNProofs, totalProofs)

  # test "simulates invalid proof every N proofs":
  #   let failEveryNProofs = 3'u
  #   let totalProofs = 12
  #   startProviderNode(failEveryNProofs)

  #   await waitUntilPurchaseIsStarted(duration=totalProofs.uint * period,
  #                                    failEveryNProofs = failEveryNProofs)
  #   await waitUntilSlotNoLongerFilled()

  #   check missed.truncate(int) == expectedMissed(failEveryNProofs, totalProofs)

  # test "does not simulate invalid proofs when --simulate-failed-proofs is 0":
  #   let failEveryNProofs = 0'u
  #   let totalProofs = 12
  #   startProviderNode(failEveryNProofs)

  #   await waitUntilPurchaseIsStarted(duration=totalProofs.uint * period,
  #                                    failEveryNProofs = failEveryNProofs)
  #   await waitUntilSlotNoLongerFilled()

  #   check missed.truncate(int) == expectedMissed(failEveryNProofs, totalProofs)

  # test "does not simulate invalid proof when --simulate-failed-proofs is 0":
  #   # 1. instantiate node manually (startNode) with --simulate-failed-proofs=0
  #   # 2. check that the number of expected missed proofs is 0
  #   check 1 == 1

  # test "does not simulate invalid proof when chainId is 1":
  #   # 1. instantiate node manually (startNode) with --simulate-failed-proofs=3
  #   # 2. check that the number of expected missed proofs is 0
  #   check 1 == 1