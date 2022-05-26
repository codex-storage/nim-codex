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

method offerStorage(market: OnChainMarket,
                    offer: StorageOffer):
                   Future[StorageOffer] {.async.} =
  var offer = offer
  offer.host = await market.signer.getAddress()
  await market.contract.offerStorage(offer)
  return offer

method selectOffer(market: OnChainMarket, offerId: array[32, byte]) {.async.} =
  await market.contract.selectOffer(offerId)

method subscribeRequests(market: OnChainMarket,
                         callback: OnRequest):
                        Future[MarketSubscription] {.async.} =
  proc onEvent(event: StorageRequested) {.upraises:[].} =
    callback(event.requestId, event.ask)
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

method subscribeSelection(market: OnChainMarket,
                          requestId: array[32, byte],
                          callback: OnSelect):
                         Future[MarketSubscription] {.async.} =
  proc onSelect(event: OfferSelected) {.upraises: [].} =
    if event.requestId == requestId:
      callback(event.offerId)
  let subscription = await market.contract.subscribe(OfferSelected, onSelect)
  return OnChainMarketSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()
