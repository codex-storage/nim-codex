import std/sequtils
import std/os
from std/times import getTime, toUnix
import pkg/chronicles
import codex/contracts
import codex/periods
import ../contracts/time
import ../contracts/deployment
import ./twonodes
import ./multinodes

logScope:
  topics = "test proofs"

twonodessuite "Proving integration test", debug1=false, debug2=false:
  let validatorDir = getTempDir() / "CodexValidator"

  var marketplace: Marketplace
  var period: uint64

  proc purchaseStateIs(client: CodexClient, id: PurchaseId, state: string): bool =
    client.getPurchase(id).option.?state == some state

  setup:
    marketplace = Marketplace.new(Marketplace.address, ethProvider)
    period = (await marketplace.config()).proofs.period.truncate(uint64)

    # Our Hardhat configuration does use automine, which means that time tracked by `ethProvider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests ethProvider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await ethProvider.advanceTime(1.u256)

  proc waitUntilPurchaseIsStarted(proofProbability: uint64 = 3,
                                  duration: uint64 = 100 * period,
                                  expiry: uint64 = 30) {.async.} =
    discard client2.postAvailability(
      size=0xFFFFF.u256,
      duration=duration.u256,
      minPrice=300.u256,
      maxCollateral=200.u256
    )
    let cid = client1.upload("some file contents").get
    let expiry = (await ethProvider.currentTime()) + expiry.u256
    let id = client1.requestStorage(
      cid,
      expiry=expiry,
      duration=duration.u256,
      proofProbability=proofProbability.u256,
      collateral=100.u256,
      reward=400.u256
    ).get
    check eventually client1.purchaseStateIs(id, "started")

  proc advanceToNextPeriod {.async.} =
    let periodicity = Periodicity(seconds: period.u256)
    let currentPeriod = periodicity.periodOf(await ethProvider.currentTime())
    let endOfPeriod = periodicity.periodEnd(currentPeriod)
    await ethProvider.advanceTimeTo(endOfPeriod + 1)

  proc startValidator: NodeProcess =
    let validator = startNode(
      [
        "--data-dir=" & validatorDir,
        "--api-port=8089",
        "--disc-port=8099",
        "--listen-addrs=/ip4/127.0.0.1/tcp/0",
        "--validator",
        "--eth-account=" & $accounts[2]
      ], debug = false
    )
    validator.waitUntilStarted()
    validator

  proc stopValidator(node: NodeProcess) =
    node.stop()
    removeDir(validatorDir)

  test "hosts submit periodic proofs for slots they fill":
    await waitUntilPurchaseIsStarted(proofProbability=1)
    var proofWasSubmitted = false
    proc onProofSubmitted(event: ProofSubmitted) =
      proofWasSubmitted = true
    let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)
    await ethProvider.advanceTime(period.u256)
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
  DebugNodes.init(client=false, ethProvider=false, validator=false):

  proc purchaseStateIs(client: CodexClient, id: PurchaseId, state: string): bool =
    client.getPurchase(id).option.?state == some state

  var marketplace: Marketplace
  var period: uint64
  var slotId: SlotId

  setup:
    marketplace = Marketplace.new(Marketplace.address, ethProvider)
    let config = await marketplace.config()
    period = config.proofs.period.truncate(uint64)
    slotId = SlotId(array[32, byte].default) # ensure we aren't reusing from prev test

    # Our Hardhat configuration does use automine, which means that time tracked by `ethProvider.currentTime()` is not
    # advanced until blocks are mined and that happens only when transaction is submitted.
    # As we use in tests ethProvider.currentTime() which uses block timestamp this can lead to synchronization issues.
    await ethProvider.advanceTime(1.u256)

  proc periods(p: Ordinal | uint): uint64 =
    when p is uint:
      p * period
    else: p.uint * period

  proc advanceToNextPeriod {.async.} =
    let periodicity = Periodicity(seconds: period.u256)
    let currentPeriod = periodicity.periodOf(await ethProvider.currentTime())
    let endOfPeriod = periodicity.periodEnd(currentPeriod)
    await ethProvider.advanceTimeTo(endOfPeriod + 1)

  proc waitUntilPurchaseIsStarted(proofProbability: uint64 = 1,
                                  duration: uint64 = 12.periods,
                                  expiry: uint64 = 4.periods) {.async.} =

    if clients().len < 1 or providers().len < 1:
      raiseAssert("must start at least one client and one ethProvider")

    let client = clients()[0].restClient
    let storageProvider = providers()[0].restClient

    discard storageProvider.postAvailability(
      size=0xFFFFF.u256,
      duration=duration.u256,
      minPrice=300.u256,
      maxCollateral=200.u256
    )
    let cid = client.upload("some file contents " & $ getTime().toUnix).get
    let expiry = (await ethProvider.currentTime()) + expiry.u256
    # avoid timing issues by filling the slot at the start of the next period
    await advanceToNextPeriod()
    let id = client.requestStorage(
      cid,
      expiry=expiry,
      duration=duration.u256,
      proofProbability=proofProbability.u256,
      collateral=100.u256,
      reward=400.u256
    ).get
    check eventually client.purchaseStateIs(id, "started")
    let purchase = client.getPurchase(id).get
    slotId = slotId(purchase.requestId, 0.u256)

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
      if slotId(event.requestId, event.slotIndex) == slotId:
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
      if slotId(event.requestId, event.slotIndex) == slotId:
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
