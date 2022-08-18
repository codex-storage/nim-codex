import std/hashes
import std/tables
import pkg/stint
import pkg/chronos
import pkg/questionable
import pkg/nimcrypto
import ./market
import ./clock

export questionable
export market

type
  Purchasing* = ref object
    market: Market
    clock: Clock
    purchases: Table[PurchaseId, Purchase]
    proofProbability*: UInt256
    requestExpiryInterval*: UInt256
  Purchase* = ref object
    future: Future[void]
    market: Market
    clock: Clock
    request*: StorageRequest
  PurchaseTimeout* = Timeout
  RequestState* = enum
    New         = 1, # [default] waiting to fill slots
    Started     = 2, # all slots filled, accepting regular proofs
    Cancelled   = 3, # not enough slots filled before expiry
    Finished    = 4, # successfully completed
    Failed      = 5  # too many nodes have failed to provide proofs, data lost
  PurchaseId* = distinct array[32, byte]

const DefaultProofProbability = 100.u256
const DefaultRequestExpiryInterval = (10 * 60).u256

proc start(purchase: Purchase) {.gcsafe.}
func id*(purchase: Purchase): PurchaseId
proc `==`*(x, y: PurchaseId): bool {.borrow.}
proc hash*(x: PurchaseId): Hash {.borrow.}
# Using {.borrow.} for toHex does not borrow correctly and causes a
# C-compilation error, so we must do it long form
proc toHex*(x: PurchaseId): string = array[32, byte](x).toHex

proc new*(_: type Purchasing, market: Market, clock: Clock): Purchasing =
  Purchasing(
    market: market,
    clock: clock,
    proofProbability: DefaultProofProbability,
    requestExpiryInterval: DefaultRequestExpiryInterval,
  )

proc populate*(purchasing: Purchasing, request: StorageRequest): StorageRequest =
  result = request
  if result.ask.proofProbability == 0.u256:
    result.ask.proofProbability = purchasing.proofProbability
  if result.expiry == 0.u256:
    result.expiry = (purchasing.clock.now().u256 + purchasing.requestExpiryInterval)
  if result.nonce == Nonce.default:
    var id = result.nonce.toArray
    doAssert randomBytes(id) == 32
    result.nonce = Nonce(id)

proc purchase*(purchasing: Purchasing, request: StorageRequest): Purchase =
  let request = purchasing.populate(request)
  let purchase = Purchase(
    request: request,
    market: purchasing.market,
    clock: purchasing.clock,
  )
  purchase.start()
  purchasing.purchases[purchase.id] = purchase
  purchase

func getPurchase*(purchasing: Purchasing, id: PurchaseId): ?Purchase =
  if purchasing.purchases.hasKey(id):
    some purchasing.purchases[id]
  else:
    none Purchase

proc run(purchase: Purchase) {.async.} =
  let market = purchase.market
  let clock = purchase.clock
  var state = RequestState.New

  proc requestStorage {.async.} =
    purchase.request = await market.requestStorage(purchase.request)

  proc waitUntilFulfilled {.async.} =
    let done = newFuture[void]()
    proc callback(_: RequestId) =
      done.complete()
    let request = purchase.request
    let subscription = await market.subscribeFulfillment(request.id, callback)
    await done
    await subscription.unsubscribe()
    state = RequestState.Started

  proc withTimeout(future: Future[void]) {.async.} =
    let expiry = purchase.request.expiry.truncate(int64)
    await future.withTimeout(clock, expiry)

  await requestStorage()
  try:
    await waitUntilFulfilled().withTimeout()
  except PurchaseTimeout as e:
    if state != RequestState.Started:
      # If contract was fulfilled, the state would be RequestState.Started.
      # Otherwise, the request would have timed out and should be considered
      # cancelled. However, the request state hasn't been updated to
      # RequestState.Cancelled yet so we can't check for that state or listen for
      # an event emission. Instead, the state will be updated when the client
      # requests to withdraw funds from the storage request.
      await market.withdrawFunds(purchase.request.id)
      state = RequestState.Cancelled
    raise e

proc start(purchase: Purchase) =
  purchase.future = purchase.run()

proc wait*(purchase: Purchase) {.async.} =
  await purchase.future

func id*(purchase: Purchase): PurchaseId =
  PurchaseId(purchase.request.id)

func cancelled*(purchase: Purchase): bool =
  purchase.future.cancelled

func finished*(purchase: Purchase): bool =
  purchase.future.finished

func error*(purchase: Purchase): ?(ref CatchableError) =
  if purchase.future.failed:
    some purchase.future.error
  else:
    none (ref CatchableError)
