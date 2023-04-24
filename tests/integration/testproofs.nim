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
  var slotId: SlotId

  setup:
    let deployment = Deployment.init()
    marketplace = Marketplace.new(!deployment.address(Marketplace), provider)
    let config = await marketplace.config()
    period = config.proofs.period.truncate(uint64)
    slotId = SlotId(array[32, byte].default) # ensure we aren't reusing from prev test

    # Our Hardhat configuration does use automine, which means that time tracked by `provider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests provider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await provider.advanceTime(1.u256)

  proc periods(p: Ordinal | uint): uint64 =
    when p is uint:
      p * period
    else: p.uint * period

  proc advanceToNextPeriod {.async.} =
    let periodicity = Periodicity(seconds: period.u256)
    let currentPeriod = periodicity.periodOf(await provider.currentTime())
    let endOfPeriod = periodicity.periodEnd(currentPeriod)
    await provider.advanceTimeTo(endOfPeriod + 1)

  proc waitUntilPurchaseIsStarted(proofProbability: uint64 = 1,
                                  duration: uint64 = 12.periods,
                                  expiry: uint64 = 4.periods) {.async.} =

    if clients().len < 1 or providers().len < 1:
      raiseAssert("must start at least one client and one provider")

    let client = clients()[0].restClient
    let storageProvider = providers()[0].restClient

    discard storageProvider.postAvailability(
      size=0xFFFFF,
      duration=duration,
      minPrice=300,
      maxCollateral=200
    )
    let cid = client.upload("some file contents " & $ getTime().toUnix)
    let expiry = (await provider.currentTime()) + expiry.u256
    # avoid timing issues by filling the slot at the start of the next period
    await advanceToNextPeriod()
    let purchase = client.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      proofProbability=proofProbability,
      collateral=100,
      reward=400
    )
    check eventually client.getPurchase(purchase){"state"} == %"started"
    let requestId = RequestId.fromHex client.getPurchase(purchase){"requestId"}.getStr
    slotId = slotId(requestId, 0.u256)

  # TODO: these are very loose tests in that they are not testing EXACTLY how
  # proofs were marked as missed by the validator. These tests should be
  # tightened so that they are showing, as an integration test, that specific
  # proofs are being marked as missed by the validator.

  test "slot is freed after too many invalid proofs submitted":
    let failEveryNProofs = 2'u
    let totalProofs = 100'u
    startProviderNode(failEveryNProofs)

    await waitUntilPurchaseIsStarted(duration=totalProofs.periods)

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.slotId == slotId:
        slotWasFreed = true
    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    for _ in 0..<totalProofs:
      if slotWasFreed:
        break
      else:
        await advanceToNextPeriod()
        await sleepAsync(1.seconds)

    check slotWasFreed

    await subscription.unsubscribe()

  test "slot is not freed when not enough invalid proofs submitted":
    let failEveryNProofs = 3'u
    let totalProofs = 12'u
    startProviderNode(failEveryNProofs)

    await waitUntilPurchaseIsStarted(duration=totalProofs.periods)

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.slotId == slotId:
        slotWasFreed = true
    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    for _ in 0..<totalProofs:
      if slotWasFreed:
        break
      else:
        await advanceToNextPeriod()
        await sleepAsync(1.seconds)

    check not slotWasFreed

    await subscription.unsubscribe()
