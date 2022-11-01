import ./statemachine
import ./states/pending
import ./states/unknown
import ./states/descriptions
import ./purchaseid

# Purchase is implemented as a state machine.
#
# It can either be a new (pending) purchase that still needs to be submitted
# on-chain, or it is a purchase that was previously submitted on-chain, and
# we're just restoring its (unknown) state after a node restart.
#
#                                                                      |
#                                                                      v
#                                         ------------------------- unknown
#        |                               /                             /
#        v                              v                             /
#     pending ----> submitted ----> started ---------> finished <----/
#                        \              \                           /
#                         \              ------------> failed <----/
#                          \                                      /
#                           --> cancelled <-----------------------

export Purchase
export purchaseid
export statemachine
export description

func new*(_: type Purchase,
          requestId: RequestId,
          market: Market,
          clock: Clock): Purchase =
  Purchase(
    future: Future[void].new(),
    requestId: requestId,
    market: market,
    clock: clock
  )

func new*(_: type Purchase,
          request: StorageRequest,
          market: Market,
          clock: Clock): Purchase =
  let purchase = Purchase.new(request.id, market, clock)
  purchase.request = some request
  return purchase

proc start*(purchase: Purchase) =
  purchase.switch(PurchasePending())

proc load*(purchase: Purchase) =
  purchase.switch(PurchaseUnknown())

proc wait*(purchase: Purchase) {.async.} =
  await purchase.future

func id*(purchase: Purchase): PurchaseId =
  PurchaseId(purchase.requestId)

func finished*(purchase: Purchase): bool =
  purchase.future.finished

func error*(purchase: Purchase): ?(ref CatchableError) =
  if purchase.future.failed:
    some purchase.future.error
  else:
    none (ref CatchableError)
