import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable/results
import pkg/codex/stores/cachestore
import pkg/codex/stores/memorystore
import pkg/codex/chunker

import ./commonstoretests
import ../helpers

suite "Cache Store":
  var
    newBlock: Block
    backingStore: MockBlockStore
    store: CacheStore

  setup:
    newBlock = Block.new("New Kids on the Block".toBytes()).tryGet()
    backingStore = MockBlockStore.new()
    backingStore.getBlock = newBlock
    store = CacheStore.new(backingStore)

  test "constructor":
    expect ValueError:
      discard CacheStore.new(backingStore, cacheSize = 1, chunkSize = 2)

    expect ValueError:
      discard CacheStore.new(backingStore, cacheSize = 99, chunkSize = 100)

  test "getBlock can return cached block":
    let
      received1 = (await store.getBlock(newBlock.cid)).tryGet()
      received2 = (await store.getBlock(newBlock.cid)).tryGet()

    check:
      newBlock == received1
      newBlock == received2
      backingStore.numberOfGetCalls == 1

  test "getBlock should return empty block immediately":
    let expectedEmptyBlock = newBlock.cid.emptyBlock

    let received = (await store.getBlock(expectedEmptyBlock.cid)).tryGet()

    check:
      expectedEmptyBlock == received
      backingStore.numberOfGetCalls == 0

commonBlockStoreTests(
  "Cache", proc: BlockStore =
    BlockStore(CacheStore.new(MemoryStore.new())))
