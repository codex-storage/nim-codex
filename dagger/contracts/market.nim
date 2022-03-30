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
    pollInterval*: Duration
  MarketSubscription = market.Subscription
  EventSubscription = ethers.Subscription
  OnChainMarketSubscription = ref object of MarketSubscription
    eventSubscription: EventSubscription

const DefaultPollInterval = 3.seconds

func new*(_: type OnChainMarket, contract: Storage): OnChainMarket =
  without signer =? contract.signer:
    raiseAssert("Storage contract should have a signer")
  OnChainMarket(
    contract: contract,
    signer: signer,
    pollInterval: DefaultPollInterval
  )

method requestStorage(market: OnChainMarket, request: StorageRequest) {.async.} =
  var request = request
  request.client = await market.signer.getAddress()
  await market.contract.requestStorage(request)

method offerStorage(market: OnChainMarket, offer: StorageOffer) {.async.} =
  var offer = offer
  offer.host = await market.signer.getAddress()
  await market.contract.offerStorage(offer)

method selectOffer(market: OnChainMarket, offerId: array[32, byte]) {.async.} =
  await market.contract.selectOffer(offerId)

method getTime(market: OnChainMarket): Future[UInt256] {.async.} =
  let provider = market.contract.provider
  let blck = !await provider.getBlock(BlockTag.latest)
  return blck.timestamp

method waitUntil*(market: OnChainMarket, expiry: UInt256) {.async.} =
  while not ((time =? await market.getTime()) and (time >= expiry)):
    await sleepAsync(market.pollInterval)

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
