import pkg/stint
import pkg/contractabi
import pkg/nimcrypto
import pkg/chronos

export stint

type
  StorageRequest* = tuple
    client: Address
    duration: UInt256
    size: UInt256
    contentHash: array[32, byte]
    proofProbability: UInt256
    maxPrice: UInt256
    expiry: UInt256
    nonce: array[32, byte]
  StorageOffer* = tuple
    host: Address
    requestId: array[32, byte]
    price: UInt256
    expiry: UInt256

func id*(request: StorageRequest): array[32, byte] =
  let encoding = AbiEncoder.encode(request)
  keccak256.digest(encoding).data

func id*(offer: StorageOffer): array[32, byte] =
  let encoding = AbiEncoder.encode(offer)
  keccak256.digest(encoding).data
