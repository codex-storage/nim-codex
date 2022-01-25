import pkg/stint
import pkg/contractabi except Address
import pkg/nimcrypto
import pkg/chronos

export stint

type
  StorageRequest* = object
    duration*: UInt256
    size*: UInt256
    contentHash*: Hash
    proofPeriod*: UInt256
    proofTimeout*: UInt256
    nonce*: array[32, byte]
  StorageBid* = object
    requestHash*: Hash
    bidExpiry*: UInt256
    price*: UInt256
  Hash = array[32, byte]
  Signature = array[65, byte]

func hashRequest*(request: StorageRequest): Hash =
  let encoding = AbiEncoder.encode: (
    "[dagger.request.v1]",
    request.duration,
    request.size,
    request.contentHash,
    request.proofPeriod,
    request.proofTimeout,
    request.nonce
  )
  keccak256.digest(encoding).data

func hashBid*(bid: StorageBid): Hash =
  let encoding = AbiEncoder.encode: (
    "[dagger.bid.v1]",
    bid.requestHash,
    bid.bidExpiry,
    bid.price
  )
  keccak256.digest(encoding).data
