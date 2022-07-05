import std/sequtils
import pkg/codex/market

export market

type
  MockMarket* = ref object of Market
    requested*: seq[StorageRequest]
    fulfilled*: seq[Fulfillment]
    signer: Address
    subscriptions: Subscriptions
  Fulfillment* = object
    requestId*: array[32, byte]
    proof*: seq[byte]
    host*: Address
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

proc new*(_: type MockMarket): MockMarket =
  MockMarket(signer: Address.example)

method getSigner*(market: MockMarket): Future[Address] {.async.} =
  return market.signer

method requestStorage*(market: MockMarket,
                       request: StorageRequest):
                      Future[StorageRequest] {.async.} =
  market.requested.add(request)
  for subscription in market.subscriptions.onRequest:
    subscription.callback(request.id, request.ask)
  return request

method getRequest(market: MockMarket,
                  id: array[32, byte]): Future[?StorageRequest] {.async.} =
  for request in market.requested:
    if request.id == id:
      return some request
  return none StorageRequest

method getHost(market: MockMarket,
               id: array[32, byte]): Future[?Address] {.async.} =
  for fulfillment in market.fulfilled:
    if fulfillment.requestId == id:
      return some fulfillment.host
  return none Address

proc fulfillRequest*(market: MockMarket,
                     requestId: array[32, byte],
                     proof: seq[byte],
                     host: Address) =
  let fulfillment = Fulfillment(requestId: requestId, proof: proof, host: host)
  market.fulfilled.add(fulfillment)
  for subscription in market.subscriptions.onFulfillment:
    if subscription.requestId == requestId:
      subscription.callback(requestId)

method fulfillRequest*(market: MockMarket,
                       requestId: array[32, byte],
                       proof: seq[byte]) {.async.} =
  market.fulfillRequest(requestid, proof, market.signer)

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
