import std/times
import pkg/asynctest/chronos/unittest
import pkg/chronos
import pkg/stint
import pkg/codex/purchasing
import pkg/codex/purchasing/states/finished
import pkg/codex/purchasing/states/started
import pkg/codex/purchasing/states/submitted
import pkg/codex/purchasing/states/unknown
import pkg/codex/purchasing/states/cancelled
import pkg/codex/purchasing/states/failed
import ./helpers/mockmarket
import ./helpers/mockclock
import ./examples
import ./helpers

asyncchecksuite "Purchasing":
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
        slots: uint8.example.uint64,
        slotSize: uint32.example.u256,
        duration: uint16.example.u256,
        reward: uint8.example.u256
      )
    )

  test "submits a storage request when asked":
    discard await purchasing.purchase(request)
    check eventually market.requested.len > 0
    check market.requested[0].ask.slots == request.ask.slots
    check market.requested[0].ask.slotSize == request.ask.slotSize
    check market.requested[0].ask.duration == request.ask.duration
    check market.requested[0].ask.reward == request.ask.reward

  test "remembers purchases":
    let purchase1 = await purchasing.purchase(request)
    let purchase2 = await purchasing.purchase(request)
    check purchasing.getPurchase(purchase1.id) == some purchase1
    check purchasing.getPurchase(purchase2.id) == some purchase2

  test "has a default value for proof probability":
    check purchasing.proofProbability != 0.u256

  test "can change default value for proof probability":
    purchasing.proofProbability = 42.u256
    discard await purchasing.purchase(request)
    check eventually market.requested.len > 0
    check market.requested[0].ask.proofProbability == 42.u256

  test "can override proof probability per request":
    request.ask.proofProbability = 42.u256
    discard await purchasing.purchase(request)
    check eventually market.requested.len > 0
    check market.requested[0].ask.proofProbability == 42.u256

  test "has a default value for request expiration interval":
    check purchasing.requestExpiryInterval != 0.u256

  test "can change default value for request expiration interval":
    purchasing.requestExpiryInterval = 42.u256
    let start = getTime().toUnix()
    discard await purchasing.purchase(request)
    check eventually market.requested.len > 0
    check market.requested[0].expiry == (start + 42).u256

  test "can override expiry time per request":
    let expiry = (getTime().toUnix() + 42).u256
    request.expiry = expiry
    discard await purchasing.purchase(request)
    check eventually market.requested.len > 0
    check market.requested[0].expiry == expiry

  test "includes a random nonce in every storage request":
    discard await purchasing.purchase(request)
    discard await purchasing.purchase(request)
    check eventually market.requested.len > 0
    check market.requested[0].nonce != market.requested[1].nonce

  test "sets client address in request":
    discard await purchasing.purchase(request)
    check eventually market.requested.len > 0
    check market.requested[0].client == await market.getSigner()

  test "succeeds when request is finished":
    let purchase = await purchasing.purchase(request)
    check eventually market.requested.len > 0
    let request = market.requested[0]
    let requestEnd = getTime().toUnix() + 42
    market.requestEnds[request.id] = requestEnd
    market.emitRequestFulfilled(request.id)
    clock.set(requestEnd)
    await purchase.wait()
    check purchase.error.isNone

  test "fails when request times out":
    let purchase = await purchasing.purchase(request)
    check eventually market.requested.len > 0
    let request = market.requested[0]
    clock.set(request.expiry.truncate(int64) + 1)
    expect PurchaseTimeout:
      await purchase.wait()

  test "checks that funds were withdrawn when purchase times out":
    let purchase = await purchasing.purchase(request)
    check eventually market.requested.len > 0
    let request = market.requested[0]
    clock.set(request.expiry.truncate(int64) + 1)
    expect PurchaseTimeout:
      await purchase.wait()
    check market.withdrawn == @[request.id]

checksuite "Purchasing state machine":

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
        slots: uint8.example.uint64,
        slotSize: uint32.example.u256,
        duration: uint16.example.u256,
        reward: uint8.example.u256
      )
    )

  test "loads active purchases from market":
    let me = await market.getSigner()
    let request1, request2, request3 = StorageRequest.example
    market.requested = @[request1, request2, request3]
    market.activeRequests[me] = @[request1.id, request2.id]
    await purchasing.load()
    check isSome purchasing.getPurchase(PurchaseId(request1.id))
    check isSome purchasing.getPurchase(PurchaseId(request2.id))
    check isNone purchasing.getPurchase(PurchaseId(request3.id))

  test "loads correct purchase.future state for purchases from market":
    let me = await market.getSigner()
    let request1, request2, request3, request4, request5 = StorageRequest.example
    market.requested = @[request1, request2, request3, request4, request5]
    market.activeRequests[me] = @[request1.id, request2.id, request3.id, request4.id, request5.id]
    market.requestState[request1.id] = RequestState.New
    market.requestState[request2.id] = RequestState.Started
    market.requestState[request3.id] = RequestState.Cancelled
    market.requestState[request4.id] = RequestState.Finished
    market.requestState[request5.id] = RequestState.Failed

    # ensure the started state doesn't error, giving a false positive test result
    market.requestEnds[request2.id] = clock.now() - 1

    await purchasing.load()
    check eventually purchasing.getPurchase(PurchaseId(request1.id)).?finished == false.some
    check eventually purchasing.getPurchase(PurchaseId(request2.id)).?finished == true.some
    check eventually purchasing.getPurchase(PurchaseId(request3.id)).?finished == true.some
    check eventually purchasing.getPurchase(PurchaseId(request4.id)).?finished == true.some
    check eventually purchasing.getPurchase(PurchaseId(request5.id)).?finished == true.some
    check eventually purchasing.getPurchase(PurchaseId(request5.id)).?error.isSome

  test "moves to PurchaseSubmitted when request state is New":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.New
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseSubmitted

  test "moves to PurchaseStarted when request state is Started":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.Started
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseStarted

  test "moves to PurchaseCancelled when request state is Cancelled":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.Cancelled
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseCancelled

  test "moves to PurchaseFinished when request state is Finished":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.Finished
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseFinished

  test "moves to PurchaseFailed when request state is Failed":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.Failed
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseFailed

  test "moves to PurchaseFailed state once RequestFailed emitted":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    let future = PurchaseStarted().run(purchase)

    market.emitRequestFailed(request.id)

    let next = await future
    check !next of PurchaseFailed

  test "moves to PurchaseFinished state once request finishes":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    let future = PurchaseStarted().run(purchase)

    clock.advance(request.ask.duration.truncate(int64))

    let next = await future
    check !next of PurchaseFinished
