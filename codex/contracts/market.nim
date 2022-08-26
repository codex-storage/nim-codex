import pkg/ethers
import pkg/upraises
import pkg/questionable
import ../market
import ./storage

export market

type
  OnChainMarket* = ref object of Market
    contract: Storage
    signer: Signer
  MarketSubscription = market.Subscription
  EventSubscription = ethers.Subscription
  OnChainMarketSubscription = ref object of MarketSubscription
    eventSubscription: EventSubscription

func new*(_: type OnChainMarket, contract: Storage): OnChainMarket =
  without signer =? contract.signer:
    raiseAssert("Storage contract should have a signer")
  OnChainMarket(
    contract: contract,
    signer: signer,
  )

method getSigner*(market: OnChainMarket): Future[Address] {.async.} =
  return await market.signer.getAddress()

method requestStorage(market: OnChainMarket,
                      request: StorageRequest):
                     Future[StorageRequest] {.async.} =
  var request = request
  request.client = await market.signer.getAddress()
  await market.contract.requestStorage(request)
  return request

method getRequest(market: OnChainMarket,
                  id: RequestId): Future[?StorageRequest] {.async.} =
  try:
    let request = await market.contract.getRequest(id)
    if request != StorageRequest.default:
      return some request
    else:
      return none StorageRequest
  except ValueError:
    # Unknown request
    return none StorageRequest

method getHost(market: OnChainMarket,
               requestId: RequestId,
               slotIndex: UInt256): Future[?Address] {.async.} =
  let slotId = slotId(requestId, slotIndex)
  let address = await market.contract.getHost(slotId)
  if address != Address.default:
    return some address
  else:
    return none Address

method fillSlot(market: OnChainMarket,
                requestId: RequestId,
                slotIndex: UInt256,
                proof: seq[byte]) {.async.} =
  await market.contract.fillSlot(requestId, slotIndex, proof)

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

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()
