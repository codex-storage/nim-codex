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

method requestStorage(market: OnChainMarket,
                      request: StorageRequest):
                     Future[StorageRequest] {.async.} =
  var request = request
  request.client = await market.signer.getAddress()
  await market.contract.requestStorage(request)
  return request

method fulfillRequest(market: OnChainMarket,
                      requestId: array[32, byte],
                      proof: seq[byte]) {.async.} =
  await market.contract.fulfillRequest(requestId, proof)

method subscribeRequests(market: OnChainMarket,
                         callback: OnRequest):
                        Future[MarketSubscription] {.async.} =
  proc onEvent(event: StorageRequested) {.upraises:[].} =
    callback(event.requestId, event.ask)
  let subscription = await market.contract.subscribe(StorageRequested, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(market: OnChainMarket,
                            requestId: array[32, byte],
                            callback: OnFulfillment):
                           Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFulfilled) {.upraises:[].} =
    if event.requestId == requestId:
      callback(event.requestId)
  let subscription = await market.contract.subscribe(RequestFulfilled, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()
