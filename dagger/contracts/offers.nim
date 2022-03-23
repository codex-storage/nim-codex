import pkg/contractabi
import pkg/nimcrypto

export contractabi

type
  StorageOffer* = tuple
    host: Address
    requestId: array[32, byte]
    price: UInt256
    expiry: UInt256

func id*(offer: StorageOffer): array[32, byte] =
  let encoding = AbiEncoder.encode(offer)
  keccak256.digest(encoding).data
