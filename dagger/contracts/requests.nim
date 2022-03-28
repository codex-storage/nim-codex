import pkg/contractabi
import pkg/nimcrypto
import pkg/ethers/fields
import pkg/questionable/results

export contractabi

type
  StorageRequest* = object
    client*: Address
    duration*: UInt256
    size*: UInt256
    contentHash*: array[32, byte]
    proofProbability*: UInt256
    maxPrice*: UInt256
    expiry*: UInt256
    nonce*: array[32, byte]

func fromTuple(_: type StorageRequest, tupl: tuple): StorageRequest =
  StorageRequest(
    client: tupl[0],
    duration: tupl[1],
    size: tupl[2],
    contentHash: tupl[3],
    proofProbability: tupl[4],
    maxPrice: tupl[5],
    expiry: tupl[6],
    nonce: tupl[7]
  )

func solidityType*(_: type StorageRequest): string =
  solidityType(StorageRequest.fieldTypes)

func encode*(encoder: var AbiEncoder, request: StorageRequest) =
  encoder.write(request.fieldValues)

func decode*(decoder: var AbiDecoder, T: type StorageRequest): ?!T =
  let tupl = ?decoder.read(StorageRequest.fieldTypes)
  success StorageRequest.fromTuple(tupl)

func id*(request: StorageRequest): array[32, byte] =
  let encoding = AbiEncoder.encode(request)
  keccak256.digest(encoding).data
