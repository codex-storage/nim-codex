import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/nimcrypto
import pkg/chronicles
import ./rng
import ./market
import ./clock
import ./proving
import ./contracts/requests
import ./sales/salesagent
import ./sales/statemachine
import ./sales/states/[downloading, unknown]

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

proc handleRequest(sales: Sales,
                   requestId: RequestId,
                   ask: StorageAsk) {.async.} =
  let availability = sales.findAvailability(ask)
  # TODO: check if random slot is actually available (not already filled)
  let slotIndex = randomSlotIndex(ask.slots)
  let agent = newSalesAgent(
    sales,
    requestId,
    availability,
    some slotIndex,
    none StorageRequest
  )

  await agent.start(ask.slots)
  await agent.switchAsync(SaleDownloading())
  sales.agents.add agent

proc load*(sales: Sales) {.async.} =
  let market = sales.market

  # TODO: restore availability from disk
  let requestIds = await market.myRequests()
  var slotIds: seq[SlotId]
  # TODO: this needs to be optimised
  for requestId in requestIds:
    let reqSlotIds = await market.mySlots(requestId)
    slotIds.add reqSlotIds
  for slotId in slotIds:
    # TODO: this needs to be optimised
    if slot =? await market.getSlot(slotId):
      if request =? await market.getRequest(slot.requestId):
        let availability = sales.findAvailability(request.ask)
        # TODO: restore slot index from chain, do not assign a new index
        let slotIndex = randomSlotIndex(request.ask.slots)
        let agent = newSalesAgent(
          sales,
          slot.requestId,
          availability,
          some slotIndex,
          some request)

        await agent.start(request.ask.slots)
        await agent.switchAsync(SaleUnknown())
        sales.agents.add agent

proc start*(sales: Sales) {.async.} =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(requestId: RequestId, ask: StorageAsk) {.gcsafe, upraises:[], async.} =
    await sales.handleRequest(requestId, ask)

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

