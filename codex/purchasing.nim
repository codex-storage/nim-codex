import std/tables
import pkg/stint
import pkg/chronos
import pkg/questionable
import pkg/nimcrypto
import ./market
import ./clock
import ./purchasing/purchase

export questionable
export market
export purchase

type
  Purchasing* = ref object
    market: Market
    clock: Clock
    purchases: Table[PurchaseId, Purchase]
    proofProbability*: UInt256
    requestExpiryInterval*: UInt256
  PurchaseTimeout* = Timeout

const DefaultProofProbability = 100.u256
const DefaultRequestExpiryInterval = (10 * 60).u256

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
  let purchase = newPurchase(request, purchasing.market, purchasing.clock)
  purchase.start()
  purchasing.purchases[purchase.id] = purchase
  purchase

func getPurchase*(purchasing: Purchasing, id: PurchaseId): ?Purchase =
  if purchasing.purchases.hasKey(id):
    some purchasing.purchases[id]
  else:
    none Purchase
