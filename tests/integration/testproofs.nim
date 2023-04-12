import codex/contracts/marketplace
import codex/contracts/deployment
import ../contracts/time
import ../codex/helpers/eventually
import ./twonodes

twonodessuite "Proving integration test", debug1=false, debug2=false:

  var marketplace: Marketplace
  var config: MarketplaceConfig

  setup:
    let deployment = Deployment.init()
    marketplace = Marketplace.new(!deployment.address(Marketplace), provider)
    config = await marketplace.config()
    await provider.advanceTime(1.u256)

  proc waitUntilPurchaseIsStarted {.async.} =
    discard client2.postAvailability(size=0xFFFFF, duration=200, minPrice=300, maxCollateral=200)
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let purchase = client1.requestStorage(cid, duration=100, reward=400, proofProbability=3, expiry=expiry, collateral=100)
    check eventually client1.getPurchase(purchase){"state"} == %"started"

  test "hosts submit periodic proofs for slots they fill":
    await waitUntilPurchaseIsStarted()

    var proofWasSubmitted = false
    proc onProofSubmitted(event: ProofSubmitted) =
      proofWasSubmitted = true
    let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)

    for _ in 0..<100:
      if proofWasSubmitted:
        break
      else:
        await provider.advanceTime(config.proofs.period)
        await sleepAsync(1.seconds)

    check proofWasSubmitted
    await subscription.unsubscribe()
