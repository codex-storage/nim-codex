import std/random
import std/sequtils
import std/times
import std/typetraits
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/rng
import pkg/codex/sales/slotqueue
import pkg/codex/stores

import pkg/stint
import ./codex/helpers/randomchunker

proc exampleString*(length: int): string =
  let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = newString(length) # Create a new empty string with a given length
  for i in 0..<length:
    result[i] = chars[rand(chars.len-1)] # Generate a random index and set the string's character

proc example*[T: SomeInteger](_: type T): T =
  rand(T)

proc example*[T,N](_: type array[N, T]): array[N, T] =
  for item in result.mitems:
    item = T.example

proc example*[T](_: type seq[T]): seq[T] =
  let length = uint8.example.int
  newSeqWith(length, T.example)

proc example*(_: type UInt256): UInt256 =
  UInt256.fromBytes(array[32, byte].example)

proc example*[T: distinct](_: type T): T =
  type baseType = T.distinctBase
  T(baseType.example)

proc example*(_: type StorageRequest): StorageRequest =
  StorageRequest(
    client: Address.example,
    ask: StorageAsk(
      slots: 4,
      slotSize: (1 * 1024 * 1024 * 1024).u256, # 1 Gigabyte
      duration: (10 * 60 * 60).u256, # 10 hours
      collateral: 200.u256,
      proofProbability: 4.u256, # require a proof roughly once every 4 periods
      reward: 84.u256,
      maxSlotLoss: 2 # 2 slots can be freed without data considered to be lost
    ),
    content: StorageContent(
      cid: "zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob",
      merkleRoot: array[32, byte].example
    ),
    expiry: (getTime() + 1.hours).toUnix.u256,
    nonce: Nonce.example
  )

proc example*(_: type Slot): Slot =
  let request = StorageRequest.example
  let slotIndex = rand(request.ask.slots.int).u256
  Slot(request: request, slotIndex: slotIndex)

proc example*(_: type SlotQueueItem): SlotQueueItem =
  let request = StorageRequest.example
  let slot = Slot.example
  SlotQueueItem.init(request, slot.slotIndex.truncate(uint16))

proc exampleProof*(): seq[byte] =
  var proof: seq[byte]
  while proof.len == 0:
    proof = seq[byte].example
  return proof

proc exampleData*(): Future[seq[byte]] {.async.} =
  let rng = rng.Rng.instance()
  let chunker = RandomChunker.new(rng, size = DefaultBlockSize * 2, chunkSize = DefaultBlockSize * 2)
  return await chunker.getBytes()
