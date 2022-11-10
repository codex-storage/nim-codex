import std/hashes
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
    nonce*: Nonce
  StorageAsk* = object
    slots*: uint64
    slotSize*: UInt256
    duration*: UInt256
    proofProbability*: UInt256
    reward*: UInt256
    maxSlotLoss*: uint64
  StorageContent* = object
    cid*: string
    erasure*: StorageErasure
    por*: StoragePoR
  StorageErasure* = object
    totalChunks*: uint64
  StoragePoR* = object
    u*: seq[byte]
    publicKey*: seq[byte]
    name*: seq[byte]
  SlotId* = distinct array[32, byte]
  RequestId* = distinct array[32, byte]
  Nonce* = distinct array[32, byte]
  RequestState* {.pure.} = enum
    New
    Started
    Cancelled
    Finished
    Failed
  Slot* = object of RootObj
    host*: Address
    hostPaid*: bool
    requestId*: RequestId

proc `==`*(x, y: Nonce): bool {.borrow.}
proc `==`*(x, y: RequestId): bool {.borrow.}
proc `==`*(x, y: SlotId): bool {.borrow.}
proc hash*(x: SlotId): Hash {.borrow.}

func toArray*(id: RequestId | SlotId | Nonce): array[32, byte] =
  array[32, byte](id)

proc `$`*(id: RequestId | SlotId | Nonce): string =
  id.toArray.toHex

func fromTuple(_: type StorageRequest, tupl: tuple): StorageRequest =
  StorageRequest(
    client: tupl[0],
    ask: tupl[1],
    content: tupl[2],
    expiry: tupl[3],
    nonce: tupl[4]
  )

func fromTuple(_: type Slot, tupl: tuple): Slot =
  Slot(
    host: tupl[0],
    hostPaid: tupl[1],
    requestId: tupl[2]
  )

func fromTuple(_: type StorageAsk, tupl: tuple): StorageAsk =
  StorageAsk(
    slots: tupl[0],
    slotSize: tupl[1],
    duration: tupl[2],
    proofProbability: tupl[3],
    reward: tupl[4],
    maxSlotLoss: tupl[5]
  )

func fromTuple(_: type StorageContent, tupl: tuple): StorageContent =
  StorageContent(
    cid: tupl[0],
    erasure: tupl[1],
    por: tupl[2]
  )

func fromTuple(_: type StorageErasure, tupl: tuple): StorageErasure =
  StorageErasure(
    totalChunks: tupl[0]
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

func solidityType*(_: type Slot): string =
  solidityType(Slot.fieldTypes)

func solidityType*[T: RequestId | SlotId | Nonce](_: type T): string =
  solidityType(array[32, byte])

func encode*(encoder: var AbiEncoder, por: StoragePoR) =
  encoder.write(por.fieldValues)

func encode*(encoder: var AbiEncoder, erasure: StorageErasure) =
  encoder.write(erasure.fieldValues)

func encode*(encoder: var AbiEncoder, content: StorageContent) =
  encoder.write(content.fieldValues)

func encode*(encoder: var AbiEncoder, ask: StorageAsk) =
  encoder.write(ask.fieldValues)

func encode*(encoder: var AbiEncoder, id: RequestId | SlotId | Nonce) =
  encoder.write(id.toArray)

func encode*(encoder: var AbiEncoder, request: StorageRequest) =
  encoder.write(request.fieldValues)

func encode*(encoder: var AbiEncoder, slot: Slot) =
  encoder.write(slot.fieldValues)

func decode*[T: RequestId | SlotId | Nonce](decoder: var AbiDecoder,
                                            _: type T): ?!T =
  let nonce = ?decoder.read(type array[32, byte])
  success T(nonce)

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

func decode*(decoder: var AbiDecoder, T: type Slot): ?!T =
  let tupl = ?decoder.read(Slot.fieldTypes)
  success Slot.fromTuple(tupl)

func id*(request: StorageRequest): RequestId =
  let encoding = AbiEncoder.encode((request, ))
  RequestId(keccak256.digest(encoding).data)

func slotId*(requestId: RequestId, slot: UInt256): SlotId =
  let encoding = AbiEncoder.encode((requestId, slot))
  SlotId(keccak256.digest(encoding).data)

func slotId*(request: StorageRequest, slot: UInt256): SlotId =
  slotId(request.id, slot)

func pricePerSlot*(ask: StorageAsk): UInt256 =
  ask.duration * ask.reward

func price*(ask: StorageAsk): UInt256 =
  ask.slots.u256 * ask.pricePerSlot

func price*(request: StorageRequest): UInt256 =
  request.ask.price

func size*(ask: StorageAsk): UInt256 =
  ask.slots.u256 * ask.slotSize
