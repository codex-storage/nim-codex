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

method subscribeRequests(market: OnChainMarket,
                         callback: OnRequest):
                        Future[MarketSubscription] {.async.} =
  proc onEvent(event: StorageRequested) {.upraises:[].} =
    callback(event.request)
  let subscription = await market.contract.subscribe(StorageRequested, onEvent)
  return OnChainMarketSubscription(eventSubscription: subscription)

method requestStorage(market: OnChainMarket, request: StorageRequest) {.async.} =
  var request = request
  request.client = await market.signer.getAddress()
  await market.contract.requestStorage(request)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()
