import std/times
import pkg/asynctest
import pkg/chronos
import pkg/stint
import pkg/dagger/purchasing
import ./helpers/mockmarket
import ./examples

suite "Purchasing":

  var purchasing: Purchasing
  var market: MockMarket
  var request: StorageRequest

  setup:
    market = MockMarket.new()
    purchasing = Purchasing.new(market)
    request = StorageRequest(
      ask: StorageAsk(
        duration: uint16.example.u256,
        size: uint32.example.u256,
      )
    )

  proc purchaseAndWait(request: StorageRequest) {.async.} =
    let purchase = purchasing.purchase(request)
    market.advanceTimeTo(market.requested[^1].expiry)
    await purchase.wait()

  test "submits a storage request when asked":
    await purchaseAndWait(request)
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
    await purchaseAndWait(request)
    check market.requested[0].ask.proofProbability == 42.u256

  test "can override proof probability per request":
    request.ask.proofProbability = 42.u256
    await purchaseAndWait(request)
    check market.requested[0].ask.proofProbability == 42.u256

  test "has a default value for request expiration interval":
    check purchasing.requestExpiryInterval != 0.u256

  test "can change default value for request expiration interval":
    purchasing.requestExpiryInterval = 42.u256
    let start = getTime().toUnix()
    await purchaseAndWait(request)
    check market.requested[0].expiry == (start + 42).u256

  test "can override expiry time per request":
    let expiry = (getTime().toUnix() + 42).u256
    request.expiry = expiry
    await purchaseAndWait(request)
    check market.requested[0].expiry == expiry

  test "includes a random nonce in every storage request":
    await purchaseAndWait(request)
    await purchaseAndWait(request)
    check market.requested[0].nonce != market.requested[1].nonce

  proc createOffer(request: StorageRequest): StorageOffer =
    StorageOffer(
      requestId: request.id,
      expiry: (getTime() + initDuration(hours = 1)).toUnix().u256
    )

  test "selects the cheapest offer":
    let purchase = purchasing.purchase(request)
    let request = market.requested[0]
    var offer1, offer2 = createOffer(request)
    offer1.price = 20.u256
    offer2.price = 10.u256
    discard await market.offerStorage(offer1)
    discard await market.offerStorage(offer2)
    market.advanceTimeTo(request.expiry)
    await purchase.wait()
    check market.selected[0] == offer2.id

  test "ignores offers that expired":
    let expired = (getTime() - initTimeInterval(hours = 1)).toUnix().u256
    let purchase = purchasing.purchase(request)
    let request = market.requested[0]
    var offer1, offer2 = request.createOffer()
    offer1.price = 20.u256
    offer2.price = 10.u256
    offer2.expiry = expired
    discard await market.offerStorage(offer1)
    discard await market.offerStorage(offer2)
    market.advanceTimeTo(request.expiry)
    await purchase.wait()
    check market.selected[0] == offer1.id

  test "has a default expiration margin for offers":
    check purchasing.offerExpiryMargin != 0.u256

  test "ignores offers that are about to expire":
    let expiryMargin = purchasing.offerExpiryMargin
    let purchase = purchasing.purchase(request)
    let request = market.requested[0]
    var offer1, offer2 = request.createOffer()
    offer1.price = 20.u256
    offer2.price = 10.u256
    offer2.expiry = getTime().toUnix().u256 + expiryMargin - 1
    discard await market.offerStorage(offer1)
    discard await market.offerStorage(offer2)
    market.advanceTimeTo(request.expiry)
    await purchase.wait()
    check market.selected[0] == offer1.id
