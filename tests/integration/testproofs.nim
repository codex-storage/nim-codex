import std/os
import codex/contracts/marketplace
import codex/contracts/deployment
import codex/periods
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers/eventually
import ./twonodes

twonodessuite "Proving integration test", debug1=false, debug2=false:

  let validatorDir = getTempDir() / "CodexValidator"

  var marketplace: Marketplace
  var period: uint64

  setup:
    marketplace = Marketplace.new(Marketplace.address, provider)
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

  test "simulates invalid proof every N proofs":
    # TODO: waiting on validation work to be completed before these tests are possible
    # 1. instantiate node manually (startNode) with --simulate-failed-proofs=3
    # 2. check that the number of expected proofs are missed
    check 1 == 1

  test "does not simulate invalid proof when --simulate-failed-proofs is 0":
    # 1. instantiate node manually (startNode) with --simulate-failed-proofs=0
    # 2. check that the number of expected missed proofs is 0
    check 1 == 1

  test "does not simulate invalid proof when chainId is 1":
    # 1. instantiate node manually (startNode) with --simulate-failed-proofs=3
    # 2. check that the number of expected missed proofs is 0
    check 1 == 1
