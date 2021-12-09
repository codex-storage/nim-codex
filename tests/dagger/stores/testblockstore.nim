import std/sequtils

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results
import pkg/dagger/rng
import pkg/dagger/stores/memorystore
import pkg/dagger/chunker

import ../helpers

suite "Memory Store":

  var store: MemoryStore
  var chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)
  var blocks: seq[?Block]

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).some)

    store = MemoryStore.new(blocks)

  test "getBlocks single":
    let blk = await store.getBlock((!blocks[0]).cid)
    check blk == blocks[0]

  test "hasBlock":
    check store.hasBlock((!blocks[0]).cid)

  test "delBlocks single":
    await store.delBlock((!blocks[0]).cid)
    await store.delBlock((!blocks[1]).cid)
    await store.delBlock((!blocks[2]).cid)

    check not store.hasBlock((!blocks[0]).cid)
    check not store.hasBlock((!blocks[1]).cid)
    check not store.hasBlock((!blocks[2]).cid)

  # test "add blocks change handler":
  #   let blocks = @[
  #     !Block.new("Block 1".toBytes),
  #     !Block.new("Block 2".toBytes),
  #     !Block.new("Block 3".toBytes),
  #   ]

  #   var triggered = false
  #   store.addChangeHandler(
  #     proc(evt: BlockStoreChangeEvt) =
  #       check evt.kind == ChangeType.Added
  #       check evt.cids == blocks.mapIt( it.cid )
  #       triggered = true
  #     , ChangeType.Added
  #   )

  #   store.putBlocks(blocks)
  #   check triggered

  # test "add blocks change handler":
  #   let blocks = @[
  #     !Block.new("Block 1".toBytes),
  #     !Block.new("Block 2".toBytes),
  #     !Block.new("Block 3".toBytes),
  #   ]

  #   var triggered = false
  #   store.addChangeHandler(
  #     proc(evt: BlockStoreChangeEvt) =
  #       check evt.kind == ChangeType.Removed
  #       check evt.cids == blocks.mapIt( it.cid )
  #       triggered = true
  #     , ChangeType.Removed
  #   )

  #   store.putBlocks(blocks)
  #   check store.hasBlock(blocks[0].cid)
  #   check store.hasBlock(blocks[1].cid)
  #   check store.hasBlock(blocks[2].cid)

  #   store.delBlocks(blocks.mapIt( it.cid ))
  #   check triggered
