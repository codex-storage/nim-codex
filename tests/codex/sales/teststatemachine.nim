import std/times
import std/sequtils
import std/sugar

import pkg/asynctest
import pkg/datastore
import pkg/questionable
import pkg/questionable/results

import pkg/codex/sales
import pkg/codex/sales/states/[downloading, cancelled, errored, filled, filling,
                               failed, proving, finished, unknown]
import pkg/codex/sales/reservations
import pkg/codex/sales/statemachine
import pkg/codex/stores/repostore

import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers/eventually
import ../examples

suite "Sales state machine":

  let availability = Availability.init(
    size=100.u256,
    duration=60.u256,
    minPrice=600.u256
  )
  var request = StorageRequest(
    ask: StorageAsk(
      slots: 4,
      slotSize: 100.u256,
      duration: 60.u256,
      reward: 10.u256,
    ),
    content: StorageContent(
      cid: "some cid"
    )
  )
  let proof = exampleProof()

  var sales: Sales
  var market: MockMarket
  var clock: MockClock
  var proving: Proving
  var slotIdx: UInt256
  var slotId: SlotId

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    proving = Proving.new()
    let repoDs = SQLiteDatastore.new(Memory).tryGet()
    let metaDs = SQLiteDatastore.new(Memory).tryGet()
    let repo = RepoStore.new(repoDs, metaDs)
    sales = Sales.new(market, clock, proving, repo)
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      discard
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      return proof
    await sales.start()
    request.expiry = (clock.now() + 42).u256
    discard await sales.reservations.reserve(availability)
    slotIdx = 0.u256
    slotId = request.slotId(slotIdx)

  teardown:
    await sales.stop()

  proc newSalesAgent(slotIdx: UInt256 = 0.u256): SalesAgent =
    let agent = sales.newSalesAgent(request.id,
                                    slotIdx,
                                    some availability,
                                    some request)
    return agent

  proc fillSlot(slotIdx: UInt256 = 0.u256) {.async.} =
    let address = await market.getSigner()
    let slot = MockSlot(requestId: request.id,
                        slotIndex: slotIdx,
                        proof: proof,
                        host: address)
    market.filled.add slot
    market.slotState[slotId(request.id, slotIdx)] = SlotState.Filled

  test "moves to SaleErrored when SaleFilled errors":
    let agent = newSalesAgent()
    market.slotState[slotId] = SlotState.Free
    await agent.switchAsync(SaleUnknown())
    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of UnexpectedSlotError
    check state.error.msg == "slot state on chain should not be 'free'"

  test "moves to SaleFilled>SaleFinished when slot state is Filled":
    let agent = newSalesAgent()
    await fillSlot()
    await agent.switchAsync(SaleUnknown())
    check (agent.state as SaleFinished).isSome

  test "moves to SaleFinished when slot state is Finished":
    let agent = newSalesAgent()
    await fillSlot()
    market.slotState[slotId] = SlotState.Finished
    agent.switch(SaleUnknown())
    check (agent.state as SaleFinished).isSome

  test "moves to SaleFinished when slot state is Paid":
    let agent = newSalesAgent()
    market.slotState[slotId] = SlotState.Paid
    agent.switch(SaleUnknown())
    check (agent.state as SaleFinished).isSome

  test "moves to SaleErrored when slot state is Failed":
    let agent = newSalesAgent()
    market.slotState[slotId] = SlotState.Failed
    agent.switch(SaleUnknown())
    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleFailedError
    check state.error.msg == "Sale failed"

  test "moves to SaleErrored when Downloading and request expires":
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      await sleepAsync(chronos.minutes(1)) # "far" in the future
    request.expiry = (getTime() + initDuration(seconds=2)).toUnix.u256
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await agent.switchAsync(SaleDownloading())
    clock.set(request.expiry.truncate(int64))
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleTimeoutError
    check state.error.msg == "Sale cancelled due to timeout"

  test "moves to SaleErrored when Downloading and request fails":
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      await sleepAsync(chronos.minutes(1)) # "far" in the future
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await agent.switchAsync(SaleDownloading())
    market.emitRequestFailed(request.id)
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleFailedError
    check state.error.msg == "Sale failed"

  test "moves to SaleErrored when Filling and request expires":
    request.expiry = (getTime() + initDuration(seconds=2)).toUnix.u256
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await agent.switchAsync(SaleFilling())
    clock.set(request.expiry.truncate(int64))
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleTimeoutError
    check state.error.msg == "Sale cancelled due to timeout"

  test "moves to SaleErrored when Filling and request fails":
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await agent.switchAsync(SaleFilling())
    market.emitRequestFailed(request.id)
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleFailedError
    check state.error.msg == "Sale failed"

  test "moves to SaleErrored when Finished and request expires":
    request.expiry = (getTime() + initDuration(seconds=2)).toUnix.u256
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.Finished
    await agent.switchAsync(SaleFinished())
    clock.set(request.expiry.truncate(int64))
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleTimeoutError
    check state.error.msg == "Sale cancelled due to timeout"

  test "moves to SaleErrored when Finished and request fails":
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.Finished
    await agent.switchAsync(SaleFinished())
    market.emitRequestFailed(request.id)
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleFailedError
    check state.error.msg == "Sale failed"

  test "moves to SaleErrored when Proving and request expires":
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      await sleepAsync(chronos.minutes(1)) # "far" in the future
      return @[]
    request.expiry = (getTime() + initDuration(seconds=2)).toUnix.u256
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await agent.switchAsync(SaleProving())
    clock.set(request.expiry.truncate(int64))
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleTimeoutError
    check state.error.msg == "Sale cancelled due to timeout"

  test "moves to SaleErrored when Proving and request fails":
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      await sleepAsync(chronos.minutes(1)) # "far" in the future
      return @[]
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await agent.switchAsync(SaleProving())
    market.emitRequestFailed(request.id)
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of SaleFailedError
    check state.error.msg == "Sale failed"

  test "moves to SaleErrored when Downloading and slot is filled by another host":
    sales.onStore = proc(request: StorageRequest,
                        slot: UInt256,
                        availability: ?Availability) {.async.} =
      await sleepAsync(chronos.minutes(1)) # "far" in the future
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await agent.switchAsync(SaleDownloading())
    market.fillSlot(request.id, agent.slotIndex, proof, Address.example)
    await sleepAsync chronos.seconds(2)

    let state = (agent.state as SaleErrored)
    check state.isSome
    check (!state).error.msg == "Slot filled by other host"

  test "moves to SaleErrored when Proving and slot is filled by another host":
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      await sleepAsync(chronos.minutes(1)) # "far" in the future
      return @[]
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await agent.switchAsync(SaleProving())
    market.fillSlot(request.id, agent.slotIndex, proof, Address.example)
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of HostMismatchError
    check state.error.msg == "Slot filled by other host"

  test "moves to SaleErrored when Filling and slot is filled by another host":
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      await sleepAsync(chronos.minutes(1)) # "far" in the future
      return @[]
    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    market.fillSlot(request.id, agent.slotIndex, proof, Address.example)
    await agent.switchAsync(SaleFilling())
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleErrored):
      fail()
    check state.error of HostMismatchError
    check state.error.msg == "Slot filled by other host"

  test "moves from SaleDownloading to SaleFinished, calling necessary callbacks":
    var onProveCalled, onStoreCalled, onClearCalled, onSaleCalled: bool
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      onProveCalled = true
      return @[]
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      onStoreCalled = true
    sales.onClear = proc(availability: ?Availability,
                         request: StorageRequest,
                         slotIndex: UInt256) =
      onClearCalled = true
    sales.onSale = proc(availability: ?Availability,
                         request: StorageRequest,
                         slotIndex: UInt256) =
      onSaleCalled = true

    let agent = newSalesAgent()
    await agent.start(request.ask.slots)
    market.requested.add request
    market.requestState[request.id] = RequestState.New
    await fillSlot(agent.slotIndex)
    await agent.switchAsync(SaleDownloading())
    market.emitRequestFulfilled(request.id)
    await sleepAsync chronos.seconds(2)

    without state =? (agent.state as SaleFinished):
      fail()
    check onProveCalled
    check onStoreCalled
    check not onClearCalled
    check onSaleCalled

  test "loads active slots from market":
    let me = await market.getSigner()

    request.ask.slots = 2
    market.requested = @[request]
    market.requestState[request.id] = RequestState.New

    let slot0 = MockSlot(requestId: request.id,
                     slotIndex: 0.u256,
                     proof: proof,
                     host: me)
    await fillSlot(slot0.slotIndex)

    let slot1 = MockSlot(requestId: request.id,
                     slotIndex: 1.u256,
                     proof: proof,
                     host: me)
    await fillSlot(slot1.slotIndex)
    market.activeSlots[me] = @[request.slotId(0.u256), request.slotId(1.u256)]
    market.requested = @[request]
    market.activeRequests[me] = @[request.id]

    await sales.load()
    let expected = SalesAgent(sales: sales,
                               requestId: request.id,
                               availability: none Availability,
                               request: some request)
    # because sales.load() calls agent.start, we won't know the slotIndex
    # randomly selected for the agent, and we also won't know the value of
    # `failed`/`fulfilled`/`cancelled` futures, so we need to compare
    # the properties we know
    # TODO: when calling sales.load(), slot index should be restored and not
    # randomly re-assigned, so this may no longer be needed
    proc `==` (agent0, agent1: SalesAgent): bool =
      return agent0.sales == agent1.sales and
             agent0.requestId == agent1.requestId and
             agent0.availability == agent1.availability and
             agent0.request == agent1.request

    check sales.agents.all(agent => agent == expected)
