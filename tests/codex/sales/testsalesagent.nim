import std/sets
import std/sequtils
import std/sugar
import std/times
import pkg/asynctest
import pkg/chronos
import pkg/codex/sales
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/sales/statemachine
import pkg/codex/sales/states/errorhandling
import pkg/codex/proving
import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers/eventually
import ../examples

var onCancelCalled = false
var onFailedCalled = false
var onSlotFilledCalled = false
var onErrorCalled = false

type
  MockState = ref object of SaleState
  MockErrorState = ref object of ErrorHandlingState

method `$`*(state: MockState): string = "MockState"

method onCancelled*(state: MockState, request: StorageRequest): ?State =
  onCancelCalled = true

method onFailed*(state: MockState, request: StorageRequest): ?State =
  onFailedCalled = true

method onSlotFilled*(state: MockState, requestId: RequestId,
                    slotIndex: UInt256): ?State =
  onSlotFilledCalled = true

method onError*(state: MockErrorState, err: ref CatchableError): ?State =
  onErrorCalled = true

method run*(state: MockErrorState, machine: Machine): Future[?State] {.async.} =
  raise newException(ValueError, "failure")

checksuite "Sales agent":

  var request = StorageRequest(
    ask: StorageAsk(
      slots: 4,
      slotSize: 100.u256,
      duration: 60.u256,
      reward: 10.u256,
    ),
    content: StorageContent(
      cid: "some cid"
    ),
    expiry: (getTime() + initDuration(hours=1)).toUnix.u256
  )

  var agent: SalesAgent
  var context: SalesContext
  var slotIndex: UInt256
  var market: MockMarket
  var clock: MockClock

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    context = SalesContext(market: market, clock: clock)
    slotIndex = 0.u256
    onCancelCalled = false
    onFailedCalled = false
    onSlotFilledCalled = false
    agent = newSalesAgent(context,
                          request.id,
                          slotIndex,
                          some request)
    request.expiry = (getTime() + initDuration(hours=1)).toUnix.u256

  teardown:
    await agent.stop()

  test "can retrieve request":
    agent = newSalesAgent(context,
                          request.id,
                          slotIndex,
                          none StorageRequest)
    market.requested = @[request]
    await agent.retrieveRequest()
    check agent.data.request == some request

  test "subscribe assigns subscriptions/futures":
    await agent.subscribe()
    check not agent.data.cancelled.isNil
    check not agent.data.failed.isNil
    check not agent.data.fulfilled.isNil
    check not agent.data.slotFilled.isNil

  test "unsubscribe deassigns subscriptions/futures":
    await agent.subscribe()
    await agent.unsubscribe()
    check agent.data.cancelled.isNil
    check agent.data.failed.isNil
    check agent.data.fulfilled.isNil
    check agent.data.slotFilled.isNil

  test "subscribe can be called multiple times, without overwriting subscriptions/futures":
    await agent.subscribe()
    let cancelled = agent.data.cancelled
    let failed = agent.data.failed
    let fulfilled = agent.data.fulfilled
    let slotFilled = agent.data.slotFilled
    await agent.subscribe()
    check cancelled == agent.data.cancelled
    check failed == agent.data.failed
    check fulfilled == agent.data.fulfilled
    check slotFilled == agent.data.slotFilled

  test "unsubscribe can be called multiple times":
    await agent.subscribe()
    await agent.unsubscribe()
    await agent.unsubscribe()

  test "subscribe can be called when request expiry has lapsed":
    # succeeds when agent.data.fulfilled.isNil
    request.expiry = (getTime() - initDuration(seconds=1)).toUnix.u256
    agent.data.request = some request
    check agent.data.fulfilled.isNil
    await agent.subscribe()

  test "current state onCancelled called when cancel emitted":
    let state = MockState.new()
    agent.start(state)
    await agent.subscribe()
    clock.set(request.expiry.truncate(int64))
    check eventually onCancelCalled

  test "cancelled future is finished (cancelled) when fulfillment emitted":
    agent.start(MockState.new())
    await agent.subscribe()
    market.emitRequestFulfilled(request.id)
    check eventually agent.data.cancelled.cancelled()

  test "current state onFailed called when failed emitted":
    agent.start(MockState.new())
    await agent.subscribe()
    market.emitRequestFailed(request.id)
    check eventually onFailedCalled

  test "current state onSlotFilled called when slot filled emitted":
    agent.start(MockState.new())
    await agent.subscribe()
    market.emitSlotFilled(request.id, slotIndex)
    check eventually onSlotFilledCalled

  test "ErrorHandlingState.onError can be overridden at the state level":
    agent.start(MockErrorState.new())
    check eventually onErrorCalled
