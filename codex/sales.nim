import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/chronicles
import pkg/datastore
import ./rng
import ./market
import ./clock
import ./proving
import ./contracts/requests
import ./sales/reservations
import ./sales/salesagent
import ./sales/statemachine
import ./sales/states/[downloading, unknown]
import ./stores

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
export reservations
export salesagent
export statemachine

func new*(_: type Sales,
          market: Market,
          clock: Clock,
          proving: Proving,
          repo: RepoStore): Sales =
  Sales(
    market: market,
    clock: clock,
    proving: proving,
    reservations: Reservations.new(repo)
  )


proc randomSlotIndex(numSlots: uint64): UInt256 =
  let rng = Rng.instance
  let slotIndex = rng.rand(numSlots - 1)
  return slotIndex.u256

proc handleRequest(sales: Sales,
                   requestId: RequestId,
                   ask: StorageAsk) {.async.} =
  without availability =? await sales.reservations.find(ask.slotSize,
                                                        ask.duration,
                                                        ask.pricePerSlot,
                                                        used = false):
    info "no availability for storage ask",
      slotSize = ask.slotSize,
      duration = ask.duration,
      pricePerSlot = ask.pricePerSlot,
      used=false
    return

  # TODO: check if random slot is actually available (not already filled)
  let slotIndex = randomSlotIndex(ask.slots)
  let agent = newSalesAgent(
    sales,
    requestId,
    slotIndex,
    # TODO: change availability to be non-optional? It doesn't make sense to move
    # forward with the sales process at this point if there is no availability
    some availability,
    none StorageRequest
  )

  await agent.start(ask.slots)
  await agent.switchAsync(SaleDownloading())
  sales.agents.add agent

proc load*(sales: Sales) {.async.} =
  let market = sales.market
  let requestIds = await market.myRequests()
  let slotIds = await market.mySlots()

  for slotId in slotIds:
    # TODO: this needs to be optimised
    if (request, slotIndex) =? (await market.getActiveSlot(slotId)):
      let availability = await sales.reservations.find(
        request.ask.slotSize,
        request.ask.duration,
        request.ask.pricePerSlot,
        used = true)

      let agent = newSalesAgent(
        sales,
        request.id,
        slotIndex,
        # TODO: change availability to be non-optional? It doesn't make sense to move
        # forward with the sales process at this point if there is no availability
        availability,
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

