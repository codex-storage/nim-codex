import pkg/contractabi
import pkg/nimcrypto

export contractabi

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

func id*(request: StorageRequest): array[32, byte] =
  let encoding = AbiEncoder.encode(request)
  keccak256.digest(encoding).data
