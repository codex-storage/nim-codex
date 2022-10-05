import std/random
import std/sequtils
import std/times
import pkg/codex/proving
import pkg/stint

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

proc example*[T: RequestId | SlotId | Nonce](_: type T): T =
  T(array[32, byte].example)

proc example*(_: type StorageRequest): StorageRequest =
  StorageRequest(
    client: Address.example,
    ask: StorageAsk(
      slots: 4,
      slotSize: (1 * 1024 * 1024 * 1024).u256, # 1 Gigabyte
      duration: (10 * 60 * 60).u256, # 10 hours
      proofProbability: 4.u256, # require a proof roughly once every 4 periods
      reward: 84.u256,
      maxSlotLoss: 2 # 2 slots can be freed without data considered to be lost
    ),
    content: StorageContent(
      cid: "zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob",
      erasure: StorageErasure(
        totalChunks: 12,
      ),
      por: StoragePor(
        u: @(array[480, byte].example),
        publicKey: @(array[96, byte].example),
        name: @(array[512, byte].example)
      )
    ),
    expiry: (getTime() + initDuration(hours=1)).toUnix.u256,
    nonce: Nonce.example
  )
