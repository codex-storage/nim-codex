import std/times
import pkg/stint
import pkg/nimcrypto
import pkg/ethers
import dagger/contracts
import ../examples

export examples

proc example*(_: type Address): Address =
  Address(array[20, byte].example)

proc example*(_: type StorageRequest): StorageRequest =
  StorageRequest(
    client: Address.example,
    duration: (10 * 60 * 60).u256, # 10 hours
    size: (1 * 1024 * 1024 * 1024).u256, # 1 Gigabyte
    contentHash: sha256.digest(0xdeadbeef'u32.toBytes).data,
    proofProbability: 4.u256, # require a proof roughly once every 4 periods
    maxPrice: 84.u256,
    expiry: (getTime() + initDuration(hours=1)).toUnix.u256,
    nonce: array[32, byte].example
  )

proc example*(_: type StorageOffer): StorageOffer =
  StorageOffer(
    host: Address.example,
    requestId: StorageRequest.example.id,
    price: 42.u256,
    expiry: (getTime() + initDuration(hours=1)).toUnix.u256,
  )
