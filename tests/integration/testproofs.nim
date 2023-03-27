import codex/contracts/marketplace
import codex/contracts/deployment
import ../contracts/time
import ../codex/helpers/eventually
import ./twonodes
import ./tokens

twonodessuite "Proving integration test", debug1=false, debug2=false:

  var marketplace: Marketplace
  var config: MarketplaceConfig

  setup:
    marketplace = Marketplace.new(!deployment().address(Marketplace), provider)
    config = await marketplace.config()
    await provider.getSigner(accounts[0]).mint()
    await provider.getSigner(accounts[1]).mint()
    await provider.getSigner(accounts[1]).deposit()

  proc waitUntilPurchaseIsStarted {.async.} =
    discard client2.postAvailability(size=0xFFFFF, duration=200, minPrice=300)
    let expiry = (await provider.currentTime()) + 30
    let cid = client1.upload("some file contents")
    let purchase = client1.requestStorage(cid, duration=100, reward=400, proofProbability=3, expiry=expiry)
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
