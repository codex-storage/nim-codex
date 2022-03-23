import std/times
import pkg/stint
import pkg/nimcrypto
import pkg/ethers
import dagger/contracts

proc randomBytes(amount: static int): array[amount, byte] =
  doAssert randomBytes(result) == amount

proc example*(_: type Address): Address =
  Address(randomBytes(20))

proc example*(_: type StorageRequest): StorageRequest =
  StorageRequest(
    client: Address.example,
    duration: (10 * 60 * 60).u256, # 10 hours
    size: (1 * 1024 * 1024 * 1024).u256, # 1 Gigabyte
    contentHash: sha256.digest(0xdeadbeef'u32.toBytes).data,
    proofProbability: 4.u256, # require a proof roughly once every 4 periods
    maxPrice: 84.u256,
    expiry: (getTime() + initDuration(hours=1)).toUnix.u256,
    nonce: randomBytes(32)
  )

proc example*(_: type StorageOffer): StorageOffer =
  StorageOffer(
    host: Address.example,
    requestId: StorageRequest.example.id,
    price: 42.u256,
    expiry: (getTime() + initDuration(hours=1)).toUnix.u256,
  )
