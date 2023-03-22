import std/times
import pkg/asynctest
import pkg/chronos
import pkg/stint
import pkg/codex/purchasing
import pkg/codex/purchasing/states/[finished, error, started, submitted, unknown]
import ./helpers/mockmarket
import ./helpers/mockclock
import ./helpers/eventually
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
        slots: uint8.example.uint64,
        slotSize: uint32.example.u256,
        duration: uint16.example.u256,
        reward: uint8.example.u256
      )
    )

  test "submits a storage request when asked":
    discard await purchasing.purchase(request)
    let submitted = market.requested[0]
    check submitted.ask.slots == request.ask.slots
    check submitted.ask.slotSize == request.ask.slotSize
    check submitted.ask.duration == request.ask.duration
    check submitted.ask.reward == request.ask.reward

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
    check market.requested[0].ask.proofProbability == 42.u256

  test "can override proof probability per request":
    request.ask.proofProbability = 42.u256
    discard await purchasing.purchase(request)
    check market.requested[0].ask.proofProbability == 42.u256

  test "has a default value for request expiration interval":
    check purchasing.requestExpiryInterval != 0.u256

  test "can change default value for request expiration interval":
    purchasing.requestExpiryInterval = 42.u256
    let start = getTime().toUnix()
    discard await purchasing.purchase(request)
    check market.requested[0].expiry == (start + 42).u256

  test "can override expiry time per request":
    let expiry = (getTime().toUnix() + 42).u256
    request.expiry = expiry
    discard await purchasing.purchase(request)
    check market.requested[0].expiry == expiry

  test "includes a random nonce in every storage request":
    discard await purchasing.purchase(request)
    discard await purchasing.purchase(request)
    check market.requested[0].nonce != market.requested[1].nonce

  test "sets client address in request":
    discard await purchasing.purchase(request)
    check market.requested[0].client == await market.getSigner()

  test "succeeds when request is finished":
    let purchase = await purchasing.purchase(request)
    let request = market.requested[0]
    let requestEnd = getTime().toUnix() + 42
    market.requestEnds[request.id] = requestEnd
    market.emitRequestFulfilled(request.id)
    clock.set(requestEnd)
    await purchase.wait()
    check purchase.error.isNone

  test "fails when request times out":
    let purchase = await purchasing.purchase(request)
    let request = market.requested[0]
    clock.set(request.expiry.truncate(int64))
    expect PurchaseTimeout:
      await purchase.wait()

  test "checks that funds were withdrawn when purchase times out":
    let purchase = await purchasing.purchase(request)
    let request = market.requested[0]
    clock.set(request.expiry.truncate(int64))
    expect PurchaseTimeout:
      await purchase.wait()
    check market.withdrawn == @[request.id]

suite "Purchasing state machine":

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
    check purchasing.getPurchase(PurchaseId(request1.id)).?finished == false.some
    check purchasing.getPurchase(PurchaseId(request2.id)).?finished == true.some
    check purchasing.getPurchase(PurchaseId(request3.id)).?finished == true.some
    check purchasing.getPurchase(PurchaseId(request4.id)).?finished == true.some
    check purchasing.getPurchase(PurchaseId(request5.id)).?finished == true.some
    check purchasing.getPurchase(PurchaseId(request5.id)).?error.isSome

  test "moves to PurchaseSubmitted when request state is New":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.New
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseSubmitted).isSome

  test "moves to PurchaseStarted when request state is Started":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.Started
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseStarted).isSome

  test "moves to PurchaseErrored when request state is Cancelled":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.Cancelled
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseErrored).isSome
    check purchase.error.?msg == "Purchase cancelled due to timeout".some

  test "moves to PurchaseFinished when request state is Finished":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.Finished
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseFinished).isSome

  test "moves to PurchaseErrored when request state is Failed":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, market, clock)
    market.requested = @[request]
    market.requestState[request.id] = RequestState.Failed
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseErrored).isSome
    check purchase.error.?msg == "Purchase failed".some

  test "moves to PurchaseErrored state once RequestFailed emitted":
    let me = await market.getSigner()
    let request = StorageRequest.example
    market.requested = @[request]
    market.activeRequests[me] = @[request.id]
    market.requestState[request.id] = RequestState.Started
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    await purchasing.load()

    # emit mock contract failure event
    market.emitRequestFailed(request.id)
    # must allow time for the callback to trigger the completion of the future
    await sleepAsync(chronos.milliseconds(10))

    # now check the result
    let purchase = purchasing.getPurchase(PurchaseId(request.id))
    let state = purchase.?state
    check (state as PurchaseErrored).isSome
    check (!purchase).error.?msg == "Purchase failed".some

  test "moves to PurchaseFinished state once request finishes":
    let me = await market.getSigner()
    let request = StorageRequest.example
    market.requested = @[request]
    market.activeRequests[me] = @[request.id]
    market.requestState[request.id] = RequestState.Started
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    await purchasing.load()

    # advance the clock to the end of the request
    clock.advance(request.ask.duration.truncate(int64))

    # now check the result
    proc requestState: ?PurchaseState =
      purchasing.getPurchase(PurchaseId(request.id)).?state as PurchaseState

    check eventually (requestState() as PurchaseFinished).isSome
