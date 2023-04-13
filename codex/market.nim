import pkg/chronos
import pkg/upraises
import pkg/questionable
import pkg/ethers/erc20
import ./contracts/requests
import ./clock
import ./periods

export chronos
export questionable
export requests
export SecondsSince1970
export periods

type
  Market* = ref object of RootObj
  Subscription* = ref object of RootObj
  OnRequest* = proc(id: RequestId, ask: StorageAsk) {.gcsafe, upraises:[].}
  OnFulfillment* = proc(requestId: RequestId) {.gcsafe, upraises: [].}
  OnSlotFilled* = proc(requestId: RequestId, slotIndex: UInt256) {.gcsafe, upraises:[].}
  OnSlotFreed* = proc(slotId: SlotId) {.gcsafe, upraises: [].}
  OnRequestCancelled* = proc(requestId: RequestId) {.gcsafe, upraises:[].}
  OnRequestFailed* = proc(requestId: RequestId) {.gcsafe, upraises:[].}
  OnProofSubmitted* = proc(id: SlotId, proof: seq[byte]) {.gcsafe, upraises:[].}

method getSigner*(market: Market): Future[Address] {.base, async.} =
  raiseAssert("not implemented")

method isMainnet*(market: Market): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method periodicity*(market: Market): Future[Periodicity] {.base, async.} =
  raiseAssert("not implemented")

method proofTimeout*(market: Market): Future[UInt256] {.base, async.} =
  raiseAssert("not implemented")

method requestStorage*(market: Market,
                       request: StorageRequest) {.base, async.} =
  raiseAssert("not implemented")

method myRequests*(market: Market): Future[seq[RequestId]] {.base, async.} =
  raiseAssert("not implemented")

method mySlots*(market: Market): Future[seq[SlotId]] {.base, async.} =
  raiseAssert("not implemented")

method getRequest*(market: Market,
                   id: RequestId):
                  Future[?StorageRequest] {.base, async.} =
  raiseAssert("not implemented")

method requestState*(market: Market,
                 requestId: RequestId): Future[?RequestState] {.base, async.} =
  raiseAssert("not implemented")

method slotState*(market: Market,
                  slotId: SlotId): Future[SlotState] {.base, async.} =
  raiseAssert("not implemented")

method getRequestEnd*(market: Market,
                      id: RequestId): Future[SecondsSince1970] {.base, async.} =
  raiseAssert("not implemented")

method getHost*(market: Market,
                requestId: RequestId,
                slotIndex: UInt256): Future[?Address] {.base, async.} =
  raiseAssert("not implemented")

method getActiveSlot*(
  market: Market,
  slotId: SlotId): Future[?Slot] {.base, async.} =

  raiseAssert("not implemented")

method fillSlot*(market: Market,
                 requestId: RequestId,
                 slotIndex: UInt256,
                 proof: seq[byte],
                 collateral: UInt256) {.base, async.} =
  raiseAssert("not implemented")

method freeSlot*(market: Market, slotId: SlotId) {.base, async.} =
  raiseAssert("not implemented")

method withdrawFunds*(market: Market,
                      requestId: RequestId) {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequests*(market: Market,
                          callback: OnRequest):
                         Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method isProofRequired*(market: Market,
                        id: SlotId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method willProofBeRequired*(market: Market,
                            id: SlotId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method submitProof*(market: Market,
                    id: SlotId,
                    proof: seq[byte]) {.base, async.} =
  raiseAssert("not implemented")

method markProofAsMissing*(market: Market,
                           id: SlotId,
                           period: Period) {.base, async.} =
  raiseAssert("not implemented")

method canProofBeMarkedAsMissing*(market: Market,
                                  id: SlotId,
                                  period: Period): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method subscribeFulfillment*(market: Market,
                             requestId: RequestId,
                             callback: OnFulfillment):
                            Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFilled*(market: Market,
                            callback: OnSlotFilled):
                           Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFilled*(market: Market,
                            requestId: RequestId,
                            slotIndex: UInt256,
                            callback: OnSlotFilled):
                           Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFreed*(market: Market,
                           callback: OnSlotFreed):
                          Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestCancelled*(market: Market,
                                  requestId: RequestId,
                                  callback: OnRequestCancelled):
                                Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestFailed*(market: Market,
                               requestId: RequestId,
                               callback: OnRequestFailed):
                             Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeProofSubmission*(market: Market,
                                 callback: OnProofSubmitted):
                                Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async, upraises:[].} =
  raiseAssert("not implemented")
