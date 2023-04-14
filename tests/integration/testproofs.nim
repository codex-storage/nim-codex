import std/sequtils
import codex/contracts/marketplace
import codex/contracts/deployment
import codex/periods
import ../contracts/time
import ../codex/helpers/eventually
import ./twonodes

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

invalidproofsuite "Simulate invalid proofs", debugClient=false, debugProvider=false:

  var marketplace: Marketplace
  var period: uint64
  var proofSubmitted: Future[void]
  var subscription: Subscription
  var submitted: seq[seq[byte]]
  var missed: UInt256
  var slotId: SlotId
  var validator: NodeProcess


  proc startValidator: NodeProcess =
    let datadir = getTempDir() / "CodexValidator"
    startNode([
      "--data-dir=" & datadir,
      "--api-port=8180",
      "--disc-port=8190",
      "--validator",
      "--eth-account=" & $accounts[2]
    ], debug = true)

  proc stopValidator(node: NodeProcess) =
    node.stop()
    removeDir(getTempDir() / "CodexValidator")

  setup:
    let deployment = Deployment.init()
    marketplace = Marketplace.new(!deployment.address(Marketplace), provider)
    period = (await marketplace.config()).proofs.period.truncate(uint64)
    await provider.getSigner(accounts[0]).mint()
    await provider.getSigner(accounts[1]).mint()
    await provider.getSigner(accounts[1]).deposit()
    proofSubmitted = newFuture[void]("proofSubmitted")
    proc onProofSubmitted(event: ProofSubmitted) =
      debugEcho ">>> proof submitted: ", event.proof
      submitted.add(event.proof)
      proofSubmitted.complete()
      proofSubmitted = newFuture[void]("proofSubmitted")
    subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)
    missed = 0.u256
    slotId = SlotId(array[32, byte].default)
    validator = startValidator()

  teardown:
    await subscription.unsubscribe()
    validator.stopValidator()

  proc waitUntilPurchaseIsStarted(proofProbability: uint64 = 3,
                                  duration: uint64 = 100 * period,
                                  expiry: uint64 = 30) {.async.} =

    if clients().len < 1 or providers().len < 1:
      raiseAssert("must start at least one client and one provider")

    let client = clients()[0].restClient
    let storageProvider = providers()[0].restClient

    discard storageProvider.postAvailability(
      size=0xFFFFF,
      duration=duration,
      minPrice=300
    )
    let cid = client.upload("some file contents " & $ getTime().toUnix)
    let expiry = (await provider.currentTime()) + expiry.u256
    let purchase = client.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      proofProbability=proofProbability,
      reward=400
    )
    check eventually client.getPurchase(purchase){"state"} == %"started"
    let requestId = RequestId.fromHex client.getPurchase(purchase){"requestId"}.getStr
    slotId = slotId(requestId, 0.u256)


  proc advanceToNextPeriod() {.async.} =
    await provider.advanceTime(period.u256)

  proc waitForProvingRounds(rounds: Positive) {.async.} =
    var rnds = rounds - 1 # proof round runs prior to advancing
    missed += await marketplace.missingProofs(slotId)

    while rnds > 0:
      await advanceToNextPeriod()
      rnds -= 1

  proc invalid(proofs: seq[seq[byte]]): uint =
    proofs.count(@[]).uint

  test "simulates invalid proof every N proofs":
    # TODO: waiting on validation work to be completed before these tests are possible
    # 1. instantiate node manually (startNode) with --simulate-failed-proofs=3
    # 2. check that the number of expected proofs are missed
    let failEveryNProofs = 3
    let totalProofs = 6
    let expectedInvalid = totalProofs div failEveryNProofs
    let expectedValid = totalProofs - expectedInvalid
    startProviderNode(failEveryNProofs.uint)

    await waitUntilPurchaseIsStarted(proofProbability=1)
    await waitForProvingRounds(totalProofs)

    check eventually submitted.len == expectedValid
    check missed.truncate(int) == expectedInvalid


  #   await waitUntilPurchaseIsStarted(proofProbability=1)
  #   var proofWasSubmitted = false
  #   proc onProofSubmitted(event: ProofSubmitted) =
  #     proofWasSubmitted = true
  #   let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)
  #   await provider.advanceTime(period.u256)
  #   check eventually proofWasSubmitted
  #   await subscription.unsubscribe()

  #   check 1 == 1

  # test "does not simulate invalid proof when --simulate-failed-proofs is 0":
  #   # 1. instantiate node manually (startNode) with --simulate-failed-proofs=0
  #   # 2. check that the number of expected missed proofs is 0
  #   check 1 == 1

  # test "does not simulate invalid proof when chainId is 1":
  #   # 1. instantiate node manually (startNode) with --simulate-failed-proofs=3
  #   # 2. check that the number of expected missed proofs is 0
  #   check 1 == 1