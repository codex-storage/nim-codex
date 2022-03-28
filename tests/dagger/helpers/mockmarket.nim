import std/sequtils
import std/heapqueue
import pkg/dagger/market

type
  MockMarket* = ref object of Market
    requested*: seq[StorageRequest]
    offered*: seq[StorageOffer]
    selected*: seq[array[32, byte]]
    subscriptions: Subscriptions
    time: UInt256
    waiting: HeapQueue[Expiry]
  Subscriptions = object
    onRequest: seq[RequestSubscription]
    onOffer: seq[OfferSubscription]
  RequestSubscription* = ref object of Subscription
    market: MockMarket
    callback: OnRequest
  OfferSubscription* = ref object of Subscription
    market: MockMarket
    requestId: array[32, byte]
    callback: OnOffer
  Expiry = object
    future: Future[void]
    expiry: UInt256

method requestStorage*(market: MockMarket, request: StorageRequest) {.async.} =
  market.requested.add(request)
  for subscription in market.subscriptions.onRequest:
    subscription.callback(request)

method offerStorage*(market: MockMarket, offer: StorageOffer) {.async.} =
  market.offered.add(offer)
  for subscription in market.subscriptions.onOffer:
    if subscription.requestId == offer.requestId:
      subscription.callback(offer)

method selectOffer*(market: MockMarket, id: array[32, byte]) {.async.} =
  market.selected.add(id)

method subscribeRequests*(market: MockMarket,
                          callback: OnRequest):
                         Future[Subscription] {.async.} =
  let subscription = RequestSubscription(
    market: market,
    callback: callback
  )
  market.subscriptions.onRequest.add(subscription)
  return subscription

method subscribeOffers*(market: MockMarket,
                        requestId: array[32, byte],
                        callback: OnOffer):
                       Future[Subscription] {.async.} =
  let subscription = OfferSubscription(
    market: market,
    requestId: requestId,
    callback: callback
  )
  market.subscriptions.onOffer.add(subscription)
  return subscription

method unsubscribe*(subscription: RequestSubscription) {.async.} =
  subscription.market.subscriptions.onRequest.keepItIf(it != subscription)

method unsubscribe*(subscription: OfferSubscription) {.async.} =
  subscription.market.subscriptions.onOffer.keepItIf(it != subscription)

func `<`(a, b: Expiry): bool =
  a.expiry < b.expiry

method waitUntil*(market: MockMarket, expiry: UInt256): Future[void] =
  let future = Future[void]()
  if expiry > market.time:
    market.waiting.push(Expiry(future: future, expiry: expiry))
  else:
    future.complete()
  future

proc advanceTimeTo*(market: MockMarket, time: UInt256) =
  doAssert(time >= market.time)
  market.time = time
  while market.waiting.len > 0 and market.waiting[0].expiry <= time:
    market.waiting.pop().future.complete()
