import std/random

import pkg/unittest2
import pkg/stew/objects
import pkg/questionable
import pkg/questionable/results

import pkg/codex/clock
import pkg/codex/stores/repostore/types
import pkg/codex/stores/repostore/coders

import ../../helpers

suite "Test coders":
  proc rand(T: type NBytes): T =
    rand(Natural).NBytes

  proc rand(E: type[enum]): E =
    let ordinals = enumRangeInt64(E)
    E(ordinals[rand(ordinals.len - 1)])

  proc rand(T: type StorageStats): T =
    StorageStats(
      quotaUsed: rand(NBytes), quotaReserved: rand(NBytes), totalBlocks: rand(Natural)
    )

  proc rand(T: type BlockMetadata): T =
    BlockMetadata(
      expiry: rand(SecondsSince1970), size: rand(NBytes), refCount: rand(Natural)
    )

  proc rand(T: type DeleteResult): T =
    DeleteResult(kind: rand(DeleteResultKind), released: rand(NBytes))

  proc rand(T: type StoreResult): T =
    StoreResult(kind: rand(StoreResultKind), used: rand(NBytes))

  test "Natural encode/decode":
    for val in newSeqWith[Natural](100, rand(Natural)) & @[Natural.low, Natural.high]:
      check:
        success(val) == Natural.decode(encode(val))

  test "StorageStats encode/decode":
    for val in newSeqWith[StorageStats](100, rand(StorageStats)):
      check:
        success(val) == StorageStats.decode(encode(val))

  test "BlockMetadata encode/decode":
    for val in newSeqWith[BlockMetadata](100, rand(BlockMetadata)):
      check:
        success(val) == BlockMetadata.decode(encode(val))

  test "DeleteResult encode/decode":
    for val in newSeqWith[DeleteResult](100, rand(DeleteResult)):
      check:
        success(val) == DeleteResult.decode(encode(val))

  test "StoreResult encode/decode":
    for val in newSeqWith[StoreResult](100, rand(StoreResult)):
      check:
        success(val) == StoreResult.decode(encode(val))
