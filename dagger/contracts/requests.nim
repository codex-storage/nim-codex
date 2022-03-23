import pkg/contractabi
import pkg/nimcrypto

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

func toTuple(request: StorageRequest): auto =
  (
    request.client,
    request.duration,
    request.size,
    request.contentHash,
    request.proofProbability,
    request.maxPrice,
    request.expiry,
    request.nonce
  )

func solidityType*(_: type StorageRequest): string =
  solidityType(typeof StorageRequest.default.toTuple)

func encode*(encoder: var AbiEncoder, request: StorageRequest) =
  encoder.write(request.toTuple)

func id*(request: StorageRequest): array[32, byte] =
  let encoding = AbiEncoder.encode(request)
  keccak256.digest(encoding).data
