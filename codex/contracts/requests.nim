import pkg/contractabi
import pkg/nimcrypto
import pkg/ethers/fields
import pkg/questionable/results

export contractabi

type
  StorageRequest* = object
    client*: Address
    ask*: StorageAsk
    content*: StorageContent
    expiry*: UInt256
    nonce*: array[32, byte]
  StorageAsk* = object
    size*: UInt256
    duration*: UInt256
    proofProbability*: UInt256
    maxPrice*: UInt256
  StorageContent* = object
    cid*: string
    erasure*: StorageErasure
    por*: StoragePoR
  StorageErasure* = object
    totalChunks*: uint64
    totalNodes*: uint64
    nodeId*: uint64
  StoragePoR* = object
    u*: seq[byte]
    publicKey*: seq[byte]
    name*: seq[byte]

func fromTuple(_: type StorageRequest, tupl: tuple): StorageRequest =
  StorageRequest(
    client: tupl[0],
    ask: tupl[1],
    content: tupl[2],
    expiry: tupl[3],
    nonce: tupl[4]
  )

func fromTuple(_: type StorageAsk, tupl: tuple): StorageAsk =
  StorageAsk(
    size: tupl[0],
    duration: tupl[1],
    proofProbability: tupl[2],
    maxPrice: tupl[3]
  )

func fromTuple(_: type StorageContent, tupl: tuple): StorageContent =
  StorageContent(
    cid: tupl[0],
    erasure: tupl[1],
    por: tupl[2]
  )

func fromTuple(_: type StorageErasure, tupl: tuple): StorageErasure =
  StorageErasure(
    totalChunks: tupl[0],
    totalNodes: tupl[1],
    nodeId: tupl[2]
  )

func fromTuple(_: type StoragePoR, tupl: tuple): StoragePoR =
  StoragePoR(
    u: tupl[0],
    publicKey: tupl[1],
    name: tupl[2]
  )

func solidityType*(_: type StoragePoR): string =
  solidityType(StoragePoR.fieldTypes)

func solidityType*(_: type StorageErasure): string =
  solidityType(StorageErasure.fieldTypes)

func solidityType*(_: type StorageContent): string =
  solidityType(StorageContent.fieldTypes)

func solidityType*(_: type StorageAsk): string =
  solidityType(StorageAsk.fieldTypes)

func solidityType*(_: type StorageRequest): string =
  solidityType(StorageRequest.fieldTypes)

func encode*(encoder: var AbiEncoder, por: StoragePoR) =
  encoder.write(por.fieldValues)

func encode*(encoder: var AbiEncoder, erasure: StorageErasure) =
  encoder.write(erasure.fieldValues)

func encode*(encoder: var AbiEncoder, content: StorageContent) =
  encoder.write(content.fieldValues)

func encode*(encoder: var AbiEncoder, ask: StorageAsk) =
  encoder.write(ask.fieldValues)

func encode*(encoder: var AbiEncoder, request: StorageRequest) =
  encoder.write(request.fieldValues)

func decode*(decoder: var AbiDecoder, T: type StoragePoR): ?!T =
  let tupl = ?decoder.read(StoragePoR.fieldTypes)
  success StoragePoR.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type StorageErasure): ?!T =
  let tupl = ?decoder.read(StorageErasure.fieldTypes)
  success StorageErasure.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type StorageContent): ?!T =
  let tupl = ?decoder.read(StorageContent.fieldTypes)
  success StorageContent.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type StorageAsk): ?!T =
  let tupl = ?decoder.read(StorageAsk.fieldTypes)
  success StorageAsk.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type StorageRequest): ?!T =
  let tupl = ?decoder.read(StorageRequest.fieldTypes)
  success StorageRequest.fromTuple(tupl)

func id*(request: StorageRequest): array[32, byte] =
  let encoding = AbiEncoder.encode((request, ))
  keccak256.digest(encoding).data
