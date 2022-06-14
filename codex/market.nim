import pkg/chronos
import pkg/upraises
import ./contracts/requests
import ./contracts/offers

export chronos
export requests
export offers

type
  Market* = ref object of RootObj
  Subscription* = ref object of RootObj
  OnRequest* = proc(id: array[32, byte], ask: StorageAsk) {.gcsafe, upraises:[].}
  OnFulfillment* = proc(requestId: array[32, byte]) {.gcsafe, upraises: [].}

method requestStorage*(market: Market,
                       request: StorageRequest):
                      Future[StorageRequest] {.base, async.} =
  raiseAssert("not implemented")

method fulfillRequest*(market: Market,
                       requestId: array[32, byte],
                       proof: seq[byte]) {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequests*(market: Market,
                          callback: OnRequest):
                         Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeFulfillment*(market: Market,
                             requestId: array[32, byte],
                             callback: OnFulfillment):
                            Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async, upraises:[].} =
  raiseAssert("not implemented")
