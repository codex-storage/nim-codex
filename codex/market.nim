import pkg/chronos
import pkg/upraises
import pkg/questionable
import ./contracts/requests

export chronos
export questionable
export requests

type
  Market* = ref object of RootObj
  Subscription* = ref object of RootObj
  OnRequest* = proc(id: array[32, byte], ask: StorageAsk) {.gcsafe, upraises:[].}
  OnFulfillment* = proc(requestId: array[32, byte]) {.gcsafe, upraises: [].}
  OnSlotFilled* = proc(requestId: array[32, byte], slotIndex: UInt256) {.gcsafe, upraises:[].}

method getSigner*(market: Market): Future[Address] {.base, async.} =
  raiseAssert("not implemented")

method requestStorage*(market: Market,
                       request: StorageRequest):
                      Future[StorageRequest] {.base, async.} =
  raiseAssert("not implemented")

method getRequest*(market: Market,
                   id: array[32, byte]):
                  Future[?StorageRequest] {.base, async.} =
  raiseAssert("not implemented")

method fulfillRequest*(market: Market,
                       requestId: array[32, byte],
                       proof: seq[byte]) {.base, async.} =
  raiseAssert("not implemented")

method getHost*(market: Market,
                requestId: array[32, byte],
                slotIndex: UInt256): Future[?Address] {.base, async.} =
  raiseAssert("not implemented")

method fillSlot*(market: Market,
                 requestId: array[32, byte],
                 slotIndex: UInt256,
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

method subscribeSlotFilled*(market: Market,
                            requestId: array[32, byte],
                            slotIndex: UInt256,
                            callback: OnSlotFilled):
                           Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async, upraises:[].} =
  raiseAssert("not implemented")
