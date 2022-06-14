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
    purchases: Table[array[32, byte], Purchase]
    proofProbability*: UInt256
    requestExpiryInterval*: UInt256
    offerExpiryMargin*: UInt256
  Purchase* = ref object
    future: Future[void]
    market: Market
    clock: Clock
    offerExpiryMargin: UInt256
    request*: StorageRequest
    offers*: seq[StorageOffer]
    selected*: ?StorageOffer
  PurchaseTimeout* = Timeout

const DefaultProofProbability = 100.u256
const DefaultRequestExpiryInterval = (10 * 60).u256
const DefaultOfferExpiryMargin = (8 * 60).u256

proc start(purchase: Purchase) {.gcsafe.}
func id*(purchase: Purchase): array[32, byte]

proc new*(_: type Purchasing, market: Market, clock: Clock): Purchasing =
  Purchasing(
    market: market,
    clock: clock,
    proofProbability: DefaultProofProbability,
    requestExpiryInterval: DefaultRequestExpiryInterval,
    offerExpiryMargin: DefaultOfferExpiryMargin
  )

proc populate*(purchasing: Purchasing, request: StorageRequest): StorageRequest =
  result = request
  if result.ask.proofProbability == 0.u256:
    result.ask.proofProbability = purchasing.proofProbability
  if result.expiry == 0.u256:
    result.expiry = (purchasing.clock.now().u256 + purchasing.requestExpiryInterval)
  if result.nonce == array[32, byte].default:
    doAssert randomBytes(result.nonce) == 32

proc purchase*(purchasing: Purchasing, request: StorageRequest): Purchase =
  let request = purchasing.populate(request)
  let purchase = Purchase(
    request: request,
    market: purchasing.market,
    clock: purchasing.clock,
    offerExpiryMargin: purchasing.offerExpiryMargin
  )
  purchase.start()
  purchasing.purchases[purchase.id] = purchase
  purchase

func getPurchase*(purchasing: Purchasing, id: array[32, byte]): ?Purchase =
  if purchasing.purchases.hasKey(id):
    some purchasing.purchases[id]
  else:
    none Purchase

proc run(purchase: Purchase) {.async.} =
  let market = purchase.market
  let clock = purchase.clock

  proc requestStorage {.async.} =
    purchase.request = await market.requestStorage(purchase.request)

  proc waitUntilFulfilled {.async.} =
    let done = newFuture[void]()
    proc callback(_: array[32, byte]) =
      done.complete()
    let request = purchase.request
    let subscription = await market.subscribeFulfillment(request.id, callback)
    try:
      await done
    finally:
      await subscription.unsubscribe()

  proc withTimeout(future: Future[void]) {.async.} =
    let expiry = purchase.request.expiry.truncate(int64)
    await future.withTimeout(clock, expiry)

  await requestStorage()
  await waitUntilFulfilled().withTimeout()

proc start(purchase: Purchase) =
  purchase.future = purchase.run()

proc wait*(purchase: Purchase) {.async.} =
  await purchase.future

func id*(purchase: Purchase): array[32, byte] =
  purchase.request.id

func finished*(purchase: Purchase): bool =
  purchase.future.finished

func error*(purchase: Purchase): ?(ref CatchableError) =
  if purchase.future.failed:
    some purchase.future.error
  else:
    none (ref CatchableError)
