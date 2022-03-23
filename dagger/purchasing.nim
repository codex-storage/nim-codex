import std/times
import pkg/stint
import pkg/chronos
import pkg/questionable
import pkg/nimcrypto
import ./market

export questionable

type
  Purchasing* = ref object
    market: Market
    proofProbability*: UInt256
    requestExpiryInterval*: UInt256
  PurchaseRequest* = object
    duration*: UInt256
    size*: UInt256
    contentHash*: array[32, byte]
    maxPrice*: UInt256
    proofProbability*: ?UInt256
    expiry*: ?UInt256
  Purchase* = ref object

const DefaultProofProbability = 100.u256
const DefaultRequestExpiryInterval = (10 * 60).u256

proc new*(_: type Purchasing, market: Market): Purchasing =
  Purchasing(
    market: market,
    proofProbability: DefaultProofProbability,
    requestExpiryInterval: DefaultRequestExpiryInterval
  )

proc getProofProbability(purchasing: Purchasing, request: PurchaseRequest): UInt256 =
  request.proofProbability |? purchasing.proofProbability

proc getExpiry(purchasing: Purchasing, request: PurchaseRequest): UInt256 =
  request.expiry |? (getTime().toUnix().u256 + purchasing.requestExpiryInterval)

proc getNonce(): array[32, byte] =
  doAssert randomBytes(result) == 32

proc purchase*(purchasing: Purchasing, request: PurchaseRequest): Purchase =
  let request = StorageRequest(
    client: Address.default, # TODO
    duration: request.duration,
    size: request.size,
    contentHash: request.contentHash,
    proofProbability: purchasing.getProofProbability(request),
    maxPrice: request.maxPrice,
    expiry: purchasing.getExpiry(request),
    nonce: getNonce()
  )
  asyncSpawn purchasing.market.requestStorage(request)

proc wait*(purchase: Purchase) {.async.} =
  discard
