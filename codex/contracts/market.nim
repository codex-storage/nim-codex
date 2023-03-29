import std/strutils
import pkg/ethers
import pkg/ethers/testing
import pkg/upraises
import pkg/questionable
import ../market
import ./marketplace

export market

type
  OnChainMarket* = ref object of Market
    contract: Marketplace
    signer: Signer
  MarketSubscription = market.Subscription
  EventSubscription = ethers.Subscription
  OnChainMarketSubscription = ref object of MarketSubscription
    eventSubscription: EventSubscription

func new*(_: type OnChainMarket, contract: Marketplace): OnChainMarket =
  without signer =? contract.signer:
    raiseAssert("Marketplace contract should have a signer")
  OnChainMarket(
    contract: contract,
    signer: signer,
  )

method getSigner*(market: OnChainMarket): Future[Address] {.async.} =
  return await market.signer.getAddress()

method myRequests*(market: OnChainMarket): Future[seq[RequestId]] {.async.} =
  return await market.contract.myRequests

method mySlots*(market: OnChainMarket): Future[seq[SlotId]] {.async.} =
  return await market.contract.mySlots()

method requestStorage(market: OnChainMarket, request: StorageRequest){.async.} =
  await market.contract.requestStorage(request)

method getRequest(market: OnChainMarket,
                  id: RequestId): Future[?StorageRequest] {.async.} =
  try:
    return some await market.contract.getRequest(id)
  except ProviderError as e:
    if e.revertReason.contains("Unknown request"):
      return none StorageRequest
    raise e

method requestState*(market: OnChainMarket,
                 requestId: RequestId): Future[?RequestState] {.async.} =
  try:
    return some await market.contract.requestState(requestId)
  except ProviderError as e:
    if e.revertReason.contains("Unknown request"):
      return none RequestState
    raise e

method slotState*(market: OnChainMarket,
                  slotId: SlotId): Future[SlotState] {.async.} =
  return await market.contract.slotState(slotId)

method getRequestEnd*(market: OnChainMarket,
                      id: RequestId): Future[SecondsSince1970] {.async.} =
  return await market.contract.requestEnd(id)

method getHost(market: OnChainMarket,
               requestId: RequestId,
               slotIndex: UInt256): Future[?Address] {.async.} =
  let slotId = slotId(requestId, slotIndex)
  let address = await market.contract.getHost(slotId)
  if address != Address.default:
    return some address
  else:
    return none Address

method getActiveSlot*(
  market: OnChainMarket,
  slotId: SlotId): Future[?Slot] {.async.} =

  try:
    return some await market.contract.getActiveSlot(slotId)
  except ProviderError as e:
    if e.revertReason.contains("Slot is free"):
      return none Slot
    raise e

method fillSlot(market: OnChainMarket,
                requestId: RequestId,
                slotIndex: UInt256,
                proof: seq[byte]) {.async.} =
  await market.contract.fillSlot(requestId, slotIndex, proof)

method withdrawFunds(market: OnChainMarket,
                     requestId: RequestId) {.async.} =
  await market.contract.withdrawFunds(requestId)

method subscribeRequests(market: OnChainMarket,
                         callback: OnRequest):
                        Future[MarketSubscription] {.async.} =
  proc onEvent(event: StorageRequested) {.upraises:[].} =
    callback(event.requestId, event.ask)
  let subscription = await market.contract.subscribe(StorageRequested, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(market: OnChainMarket,
                            requestId: RequestId,
                            slotIndex: UInt256,
                            callback: OnSlotFilled):
                           Future[MarketSubscription] {.async.} =
  proc onEvent(event: SlotFilled) {.upraises:[].} =
    if event.requestId == requestId and event.slotIndex == slotIndex:
      callback(event.requestId, event.slotIndex)
  let subscription = await market.contract.subscribe(SlotFilled, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(market: OnChainMarket,
                            requestId: RequestId,
                            callback: OnFulfillment):
                           Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFulfilled) {.upraises:[].} =
    if event.requestId == requestId:
      callback(event.requestId)
  let subscription = await market.contract.subscribe(RequestFulfilled, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestCancelled*(market: OnChainMarket,
                                  requestId: RequestId,
                                  callback: OnRequestCancelled):
                                Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestCancelled) {.upraises:[].} =
    if event.requestId == requestId:
      callback(event.requestId)
  let subscription = await market.contract.subscribe(RequestCancelled, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestFailed*(market: OnChainMarket,
                              requestId: RequestId,
                              callback: OnRequestFailed):
                            Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFailed) {.upraises:[]} =
    if event.requestId == requestId:
      callback(event.requestId)
  let subscription = await market.contract.subscribe(RequestFailed, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()
