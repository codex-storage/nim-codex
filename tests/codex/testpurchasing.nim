import std/times
import pkg/asynctest
import pkg/chronos
import pkg/upraises
import pkg/stint
import pkg/codex/purchasing
import pkg/codex/purchasing/states/[finished, failed, error, started, submitted, unknown]
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
        slots: uint8.example.uint64,
        slotSize: uint32.example.u256,
        duration: uint16.example.u256,
        reward: uint8.example.u256
      )
    )

  test "submits a storage request when asked":
    discard purchasing.purchase(request)
    let submitted = market.requested[0]
    check submitted.ask.slots == request.ask.slots
    check submitted.ask.slotSize == request.ask.slotSize
    check submitted.ask.duration == request.ask.duration
    check submitted.ask.reward == request.ask.reward

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

  test "succeeds when request is finished":
    let purchase = purchasing.purchase(request)
    let request = market.requested[0]
    let requestEnd = getTime().toUnix() + 42
    market.requestEnds[request.id] = requestEnd
    market.emitRequestFulfilled(request.id)
    clock.set(requestEnd)
    await purchase.wait()
    check purchase.error.isNone

  test "fails when request times out":
    let purchase = purchasing.purchase(request)
    let request = market.requested[0]
    clock.set(request.expiry.truncate(int64))
    expect PurchaseTimeout:
      await purchase.wait()

  test "checks that funds were withdrawn when purchase times out":
    let purchase = purchasing.purchase(request)
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
    market.state[request1.id] = RequestState.New
    market.state[request2.id] = RequestState.Started
    market.state[request3.id] = RequestState.Cancelled
    market.state[request4.id] = RequestState.Finished
    market.state[request5.id] = RequestState.Failed

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
    let purchase = request.newPurchase(market, clock)
    market.state[request.id] = RequestState.New
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseSubmitted).isSome

  test "moves to PurchaseStarted when request state is Started":
    let request = StorageRequest.example
    let purchase = request.newPurchase(market, clock)
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    market.state[request.id] = RequestState.Started
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseStarted).isSome

  test "moves to PurchaseError when request state is Cancelled":
    let request = StorageRequest.example
    let purchase = request.newPurchase(market, clock)
    market.state[request.id] = RequestState.Cancelled
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseError).isSome
    check purchase.error.?msg == "Purchase cancelled due to timeout".some

  test "moves to PurchaseFinished when request state is Finished":
    let request = StorageRequest.example
    let purchase = request.newPurchase(market, clock)
    market.state[request.id] = RequestState.Finished
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseFinished).isSome

  test "moves to PurchaseError when request state is Failed":
    let request = StorageRequest.example
    let purchase = request.newPurchase(market, clock)
    market.state[request.id] = RequestState.Failed
    purchase.switch(PurchaseUnknown())
    check (purchase.state as PurchaseError).isSome
    check purchase.error.?msg == "Purchase failed".some

  test "moves to PurchaseError state once RequestFailed emitted":
    let me = await market.getSigner()
    let request = StorageRequest.example
    market.requested = @[request]
    market.activeRequests[me] = @[request.id]
    market.state[request.id] = RequestState.Started
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    await purchasing.load()

    # emit mock contract failure event
    market.emitRequestFailed(request.id)
    # must allow time for the callback to trigger the completion of the future
    await sleepAsync(chronos.milliseconds(10))

    # now check the result
    let purchase = purchasing.getPurchase(PurchaseId(request.id))
    let state = purchase.?state
    check (state as PurchaseError).isSome
    check (!purchase).error.?msg == "Purchase failed".some

  test "moves to PurchaseFinished state once request finishes":
    let me = await market.getSigner()
    let request = StorageRequest.example
    market.requested = @[request]
    market.activeRequests[me] = @[request.id]
    market.state[request.id] = RequestState.Started
    market.requestEnds[request.id] = clock.now() + request.ask.duration.truncate(int64)
    await purchasing.load()

    # advance the clock to the end of the request
    clock.advance(request.ask.duration.truncate(int64))
    # must let the clock tick over, which happens every second in the same event
    # loop, so wait just over 1 second to ensure it has ticked
    await sleepAsync(chronos.seconds(1) + chronos.milliseconds(10))

    # now check the result
    let state = purchasing.getPurchase(PurchaseId(request.id)).?state
    check (state as PurchaseFinished).isSome
