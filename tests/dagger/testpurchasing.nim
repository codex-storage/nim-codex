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
      duration: uint16.example.u256,
      size: uint32.example.u256,
      contentHash: array[32, byte].example
    )

  proc purchaseAndWait(request: StorageRequest) {.async.} =
    let purchase = purchasing.purchase(request)
    market.advanceTimeTo(market.requested[^1].expiry)
    await purchase.wait()

  test "submits a storage request when asked":
    await purchaseAndWait(request)
    let submitted = market.requested[0]
    check submitted.duration == request.duration
    check submitted.size == request.size
    check submitted.contentHash == request.contentHash
    check submitted.maxPrice == request.maxPrice

  test "has a default value for proof probability":
    check purchasing.proofProbability != 0.u256

  test "can change default value for proof probability":
    purchasing.proofProbability = 42.u256
    await purchaseAndWait(request)
    check market.requested[0].proofProbability == 42.u256

  test "can override proof probability per request":
    request.proofProbability = 42.u256
    await purchaseAndWait(request)
    check market.requested[0].proofProbability == 42.u256

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

  test "selects the cheapest offer":
    let purchase = purchasing.purchase(request)
    let request = market.requested[0]
    let offer1 = StorageOffer(requestId: request.id, price: 20.u256)
    let offer2 = StorageOffer(requestId: request.id, price: 10.u256)
    await market.offerStorage(offer1)
    await market.offerStorage(offer2)
    market.advanceTimeTo(request.expiry)
    await purchase.wait()
    check market.selected[0] == offer2.id
