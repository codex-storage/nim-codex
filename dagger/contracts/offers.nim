import pkg/contractabi
import pkg/nimcrypto

export contractabi

type
  StorageOffer* = object
    host*: Address
    requestId*: array[32, byte]
    price*: UInt256
    expiry*: UInt256

func toTuple(offer: StorageOffer): auto =
  (
    offer.host,
    offer.requestId,
    offer.price,
    offer.expiry
  )

func solidityType*(_: type StorageOffer): string =
  solidityType(typeof StorageOffer.default.toTuple)

func encode*(encoder: var AbiEncoder, offer: StorageOffer) =
  encoder.write(offer.toTuple)

func id*(offer: StorageOffer): array[32, byte] =
  let encoding = AbiEncoder.encode(offer)
  keccak256.digest(encoding).data
