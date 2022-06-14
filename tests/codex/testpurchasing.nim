import std/times
import pkg/asynctest
import pkg/chronos
import pkg/stint
import pkg/codex/purchasing
import ./helpers/mockmarket
import ./helpers/mockclock
import ./examples

suite "Purchasing":

  var purchasing: Purchasing
  var market: MockMarket
  var clock: MockClock
  var request: StorageRequest

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    purchasing = Purchasing.new(market, clock)
    request = StorageRequest(
      ask: StorageAsk(
        duration: uint16.example.u256,
        size: uint32.example.u256,
      )
    )

  test "submits a storage request when asked":
    discard purchasing.purchase(request)
    let submitted = market.requested[0]
    check submitted.ask.duration == request.ask.duration
    check submitted.ask.size == request.ask.size
    check submitted.ask.maxPrice == request.ask.maxPrice

  test "remembers purchases":
    let purchase1 = purchasing.purchase(request)
    let purchase2 = purchasing.purchase(request)
    check purchasing.getPurchase(purchase1.id) == some purchase1
    check purchasing.getPurchase(purchase2.id) == some purchase2

  test "has a default value for proof probability":
    check purchasing.proofProbability != 0.u256

  test "can change default value for proof probability":
    purchasing.proofProbability = 42.u256
    discard purchasing.purchase(request)
    check market.requested[0].ask.proofProbability == 42.u256

  test "can override proof probability per request":
    request.ask.proofProbability = 42.u256
    discard purchasing.purchase(request)
    check market.requested[0].ask.proofProbability == 42.u256

  test "has a default value for request expiration interval":
    check purchasing.requestExpiryInterval != 0.u256

  test "can change default value for request expiration interval":
    purchasing.requestExpiryInterval = 42.u256
    let start = getTime().toUnix()
    discard purchasing.purchase(request)
    check market.requested[0].expiry == (start + 42).u256

  test "can override expiry time per request":
    let expiry = (getTime().toUnix() + 42).u256
    request.expiry = expiry
    discard purchasing.purchase(request)
    check market.requested[0].expiry == expiry

  test "includes a random nonce in every storage request":
    discard purchasing.purchase(request)
    discard purchasing.purchase(request)
    check market.requested[0].nonce != market.requested[1].nonce

  test "succeeds when request is fulfilled":
    let purchase = purchasing.purchase(request)
    let request = market.requested[0]
    let proof = seq[byte].example
    await market.fulfillRequest(request.id, proof)
    await purchase.wait()
    check purchase.error.isNone

  test "fails when request times out":
    let purchase = purchasing.purchase(request)
    let request = market.requested[0]
    clock.set(request.expiry.truncate(int64))
    expect PurchaseTimeout:
      await purchase.wait()
