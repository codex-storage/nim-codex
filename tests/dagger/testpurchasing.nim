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
  var purchaseRequest: PurchaseRequest

  setup:
    market = MockMarket.new()
    purchasing = Purchasing.new(market)
    purchaseRequest = PurchaseRequest.example

  test "submits a storage request when asked":
    await purchasing.purchase(purchaseRequest).wait()
    let storageRequest = market.requests[0]
    check storageRequest.duration == purchaseRequest.duration
    check storageRequest.size == purchaseRequest.size
    check storageRequest.contentHash == purchaseRequest.contentHash
    check storageRequest.maxPrice == purchaseRequest.maxPrice

  test "has a default value for proof probability":
    check purchasing.proofProbability != 0.u256

  test "can change default value for proof probability":
    purchasing.proofProbability = 42.u256
    await purchasing.purchase(purchaseRequest).wait()
    check market.requests[0].proofProbability == 42.u256

  test "can override proof probability per request":
    purchaseRequest.proofProbability = some 42.u256
    await purchasing.purchase(purchaseRequest).wait()
    check market.requests[0].proofProbability == 42.u256

  test "has a default value for request expiration interval":
    check purchasing.requestExpiryInterval != 0.u256

  test "can change default value for request expiration interval":
    purchasing.requestExpiryInterval = 42.u256
    let start = getTime().toUnix()
    await purchasing.purchase(purchaseRequest).wait()
    check market.requests[0].expiry == (start + 42).u256

  test "can override expiry time per request":
    let expiry = (getTime().toUnix() + 42).u256
    purchaseRequest.expiry = some expiry
    await purchasing.purchase(purchaseRequest).wait()
    check market.requests[0].expiry == expiry

  test "includes a random nonce in every storage request":
    await purchasing.purchase(purchaseRequest).wait()
    await purchasing.purchase(purchaseRequest).wait()
    check market.requests[0].nonce != market.requests[1].nonce
