import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import pkg/stint
import pkg/nimcrypto
import pkg/chronicles
import ./rng
import ./market
import ./clock
import ./proving
import ./errors
import ./contracts/requests
import ./sales/salesagent
import ./sales/statemachine
import ./sales/states/unknown

## Sales holds a list of available storage that it may sell.
##
## When storage is requested on the market that matches availability, the Sales
## object will instruct the Codex node to persist the requested data. Once the
## data has been persisted, it uploads a proof of storage to the market in an
## attempt to win a storage contract.
##
##    Node                        Sales                   Market
##     |                          |                         |
##     | -- add availability  --> |                         |
##     |                          | <-- storage request --- |
##     | <----- store data ------ |                         |
##     | -----------------------> |                         |
##     |                          |                         |
##     | <----- prove data ----   |                         |
##     | -----------------------> |                         |
##     |                          | ---- storage proof ---> |

export stint
export salesagent
export statemachine

type
  SalesError = object of CodexError

func new*(_: type Sales,
          market: Market,
          clock: Clock,
          proving: Proving): Sales =
  Sales(
    market: market,
    clock: clock,
    proving: proving
  )

proc init*(_: type Availability,
          size: UInt256,
          duration: UInt256,
          minPrice: UInt256): Availability =
  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: id, size: size, duration: duration, minPrice: minPrice)

proc randomSlotIndex(numSlots: uint64): UInt256 =
  let rng = Rng.instance
  let slotIndex = rng.rand(numSlots - 1)
  return slotIndex.u256

proc findSlotIndex(numSlots: uint64,
                   requestId: RequestId,
                   slotId: SlotId): ?UInt256 =
  for i in 0..<numSlots:
    if slotId(requestId, i.u256) == slotId:
      return some i.u256

  return none UInt256

proc handleRequest(sales: Sales,
                   requestId: RequestId,
                   ask: StorageAsk) {.raises:[CatchableError].} =
  let availability = sales.findAvailability(ask)
  # TODO: check if random slot is actually available (not already filled)
  let slotIndex = randomSlotIndex(ask.slots)

  let agent = newSalesAgent(
    sales,
    slotIndex,
    availability,
    requestId,
    none StorageRequest,
    RequestState.New,
    SlotState.Free
  )
  waitFor agent.start()
  sales.agents.add agent

proc load*(sales: Sales) {.async.} =
  let market = sales.market

  # TODO: restore availability from disk
  let requestIds = await market.myRequests()
  let slotIds = await market.mySlots()

  for slotId in slotIds:
    # TODO: this needs to be optimised
    if request =? await market.getRequestFromSlotId(slotId):
      let availability = sales.findAvailability(request.ask)
      without slotIndex =? findSlotIndex(request.ask.slots,
                                          request.id,
                                          slotId):
        raise newException(SalesError, "could not find slot index")

      # TODO: should be optimised (maybe get everything in one call: request, request state, slot state)
      without requestState =? await market.requestState(request.id):
        raise newException(SalesError, "request state could not be determined")

      let slotState = await market.slotState(slotId)

      let agent = newSalesAgent(
        sales,
        slotIndex,
        availability,
        request.id,
        some request,
        requestState,
        slotState,
        restoredFromChain = true)
      await agent.start()
      sales.agents.add agent

proc start*(sales: Sales) {.async.} =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(requestId: RequestId, ask: StorageAsk) {.gcsafe, upraises:[].} =
    try:
      sales.handleRequest(requestId, ask)
    except CatchableError as e:
      error "Failed to handle storage request", error = e.msg

  try:
    sales.subscription = some await sales.market.subscribeRequests(onRequest)
  except CatchableError as e:
    error "Unable to start sales", msg = e.msg

proc stop*(sales: Sales) {.async.} =
  if subscription =? sales.subscription:
    sales.subscription = market.Subscription.none
    try:
      await subscription.unsubscribe()
    except CatchableError as e:
      warn "Unsubscribe failed", msg = e.msg

  for agent in sales.agents:
    await agent.stop()

