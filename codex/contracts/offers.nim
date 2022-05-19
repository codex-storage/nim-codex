import pkg/contractabi
import pkg/nimcrypto
import pkg/ethers/fields
import pkg/questionable/results

export contractabi

type
  StorageOffer* = object
    host*: Address
    requestId*: array[32, byte]
    price*: UInt256
    expiry*: UInt256

func fromTuple(_: type StorageOffer, tupl: tuple): StorageOffer =
  StorageOffer(
    host: tupl[0],
    requestId: tupl[1],
    price: tupl[2],
    expiry: tupl[3]
  )

func solidityType*(_: type StorageOffer): string =
  solidityType(StorageOffer.fieldTypes)

func encode*(encoder: var AbiEncoder, offer: StorageOffer) =
  encoder.write(offer.fieldValues)

func decode*(decoder: var AbiDecoder, T: type StorageOffer): ?!T =
  let tupl = ?decoder.read(StorageOffer.fieldTypes)
  success StorageOffer.fromTuple(tupl)

func id*(offer: StorageOffer): array[32, byte] =
  let encoding = AbiEncoder.encode(offer)
  keccak256.digest(encoding).data
