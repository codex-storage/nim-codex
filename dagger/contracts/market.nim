import pkg/ethers
import pkg/upraises
import pkg/questionable
import ../market
import ./storage

type
  OnChainMarket* = ref object of Market
    contract: Storage
    signer: Signer
  MarketSubscription = market.Subscription
  EventSubscription = ethers.Subscription
  OnChainMarketSubscription = ref object of MarketSubscription
    eventSubscription: EventSubscription

export market

func new*(_: type OnChainMarket, contract: Storage): OnChainMarket =
  without signer =? contract.signer:
    raiseAssert("Storage contract should have a signer")
  OnChainMarket(contract: contract, signer: signer)

method requestStorage(market: OnChainMarket, request: StorageRequest) {.async.} =
  var request = request
  request.client = await market.signer.getAddress()
  await market.contract.requestStorage(request)

method offerStorage(market: OnChainMarket, offer: StorageOffer) {.async.} =
  var offer = offer
  offer.host = await market.signer.getAddress()
  await market.contract.offerStorage(offer)

method subscribeRequests(market: OnChainMarket,
                         callback: OnRequest):
                        Future[MarketSubscription] {.async.} =
  proc onEvent(event: StorageRequested) {.upraises:[].} =
    callback(event.request)
  let subscription = await market.contract.subscribe(StorageRequested, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeOffers(market: OnChainMarket,
                       requestId: array[32, byte],
                       callback: OnOffer):
                      Future[MarketSubscription] {.async.} =
  proc onEvent(event: StorageOffered) {.upraises:[].} =
    if event.requestId == requestId:
      callback(event.offer)
  let subscription = await market.contract.subscribe(StorageOffered, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()
