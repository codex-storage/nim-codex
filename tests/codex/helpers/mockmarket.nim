import std/sequtils
import pkg/codex/market

export market

type
  MockMarket* = ref object of Market
    requested*: seq[StorageRequest]
    fulfilled*: seq[Fulfillment]
    subscriptions: Subscriptions
  Fulfillment* = object
    requestId: array[32, byte]
    proof: seq[byte]
  Subscriptions = object
    onRequest: seq[RequestSubscription]
    onFulfillment: seq[FulfillmentSubscription]
  RequestSubscription* = ref object of Subscription
    market: MockMarket
    callback: OnRequest
  FulfillmentSubscription* = ref object of Subscription
    market: MockMarket
    requestId: array[32, byte]
    callback: OnFulfillment

method requestStorage*(market: MockMarket,
                       request: StorageRequest):
                      Future[StorageRequest] {.async.} =
  market.requested.add(request)
  for subscription in market.subscriptions.onRequest:
    subscription.callback(request.id, request.ask)
  return request

method fulfillRequest*(market: MockMarket,
                       requestId: array[32, byte],
                       proof: seq[byte]) {.async.} =
  market.fulfilled.add(Fulfillment(requestId: requestId, proof: proof))
  for subscription in market.subscriptions.onFulfillment:
    if subscription.requestId == requestId:
      subscription.callback(requestId)

method subscribeRequests*(market: MockMarket,
                          callback: OnRequest):
                         Future[Subscription] {.async.} =
  let subscription = RequestSubscription(
    market: market,
    callback: callback
  )
  market.subscriptions.onRequest.add(subscription)
  return subscription

method subscribeFulfillment*(market: MockMarket,
                             requestId: array[32, byte],
                             callback: OnFulfillment):
                            Future[Subscription] {.async.} =
  let subscription = FulfillmentSubscription(
    market: market,
    requestId: requestId,
    callback: callback
  )
  market.subscriptions.onFulfillment.add(subscription)
  return subscription

method unsubscribe*(subscription: RequestSubscription) {.async.} =
  subscription.market.subscriptions.onRequest.keepItIf(it != subscription)

method unsubscribe*(subscription: FulfillmentSubscription) {.async.} =
  subscription.market.subscriptions.onFulfillment.keepItIf(it != subscription)
