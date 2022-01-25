import std/times
import pkg/stint
import pkg/nimcrypto
import dagger/contracts/marketplace

proc randomBytes(amount: static int): array[amount, byte] =
  doAssert randomBytes(result) == amount

proc example*(_: type StorageRequest): StorageRequest =
  StorageRequest(
    duration: 150.u256, # 150 blocks ≈ half an hour
    size: (1 * 1024 * 1024 * 1024).u256, # 1 Gigabyte
    contentHash: sha256.digest(0xdeadbeef'u32.toBytes).data,
    proofPeriod: 8.u256, # 8 blocks ≈ 2 minutes
    proofTimeout: 4.u256, # 4 blocks ≈ 1 minute
    nonce: randomBytes(32)
  )

proc example*(_: type StorageBid): StorageBid =
  StorageBid(
    requestHash: hashRequest(StorageRequest.example),
    bidExpiry: (getTime() + initDuration(hours=1)).toUnix.u256,
    price: 42.u256
  )

proc example*(_: type (StorageRequest, StorageBid)): (StorageRequest, StorageBid) =
  result[0] = StorageRequest.example
  result[1] = StorageBid.example
  result[1].requestHash = hashRequest(result[0])
