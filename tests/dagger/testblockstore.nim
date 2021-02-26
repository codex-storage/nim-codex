import std/sequtils
import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils

import pkg/dagger/p2p/rng
import pkg/dagger/stores/memorystore
import pkg/dagger/chunker

import ./helpers

suite "Memory Store":

  var store: MemoryStore
  var chunker = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
  var blocks = chunker.mapIt( Block.new(it) )

  setup:
    store = MemoryStore.new(blocks)

  test "getBlocks single":
    let blk = await store.getBlocks(@[blocks[0].cid])
    check blk[0] == blocks[0]

  test "getBlocks multiple":
    let blk = await store.getBlocks(blocks[0..2].mapIt( it.cid ))
    check blk == blocks[0..2]

  test "hasBlock":
    check store.hasBlock(blocks[0].cid)

  test "delBlocks single":
    let blks = blocks[1..3].mapIt( it.cid )
    store.delBlocks(blks)

    check not store.hasBlock(blks[0])
    check not store.hasBlock(blks[1])
    check not store.hasBlock(blks[2])

  test "add blocks change handler":
    let blocks = @[
      Block.new("Block 1".toBytes),
      Block.new("Block 2".toBytes),
      Block.new("Block 3".toBytes),
    ]

    var triggered = false
    store.addChangeHandler(
      proc(evt: BlockStoreChangeEvt) =
        check evt.kind == ChangeType.Added
        check evt.cids == blocks.mapIt( it.cid )
        triggered = true
      , ChangeType.Added
    )

    store.putBlocks(blocks)
    check triggered

  test "add blocks change handler":
    let blocks = @[
      Block.new("Block 1".toBytes),
      Block.new("Block 2".toBytes),
      Block.new("Block 3".toBytes),
    ]

    var triggered = false
    store.addChangeHandler(
      proc(evt: BlockStoreChangeEvt) =
        check evt.kind == ChangeType.Removed
        check evt.cids == blocks.mapIt( it.cid )
        triggered = true
      , ChangeType.Removed
    )

    store.putBlocks(blocks)
    check store.hasBlock(blocks[0].cid)
    check store.hasBlock(blocks[1].cid)
    check store.hasBlock(blocks[2].cid)

    store.delBlocks(blocks.mapIt( it.cid ))
    check triggered
