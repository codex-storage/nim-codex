import std/sequtils
import std/strutils
import std/options

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable/results
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/manifest

import ../helpers

type
  StoreProvider* = proc(): BlockStore {.gcsafe.}

proc commonBlockStoreTests*(name: string, provider: StoreProvider) =
  suite name & " Store Common":
    var
      newBlock, newBlock1, newBlock2, newBlock3: Block
      store: BlockStore

    setup:
      newBlock = Block.new("New Kids on the Block".toBytes()).tryGet()
      newBlock1 = Block.new("1".repeat(100).toBytes()).tryGet()
      newBlock2 = Block.new("2".repeat(100).toBytes()).tryGet()
      newBlock3 = Block.new("3".repeat(100).toBytes()).tryGet()
      store = provider()

    teardown:
      await store.close()

    test "putBlock":
      (await store.putBlock(newBlock1)).tryGet()
      check (await store.hasBlock(newBlock1.cid)).tryGet()

    test "getBlock":
      (await store.putBlock(newBlock)).tryGet()
      let blk = await store.getBlock(newBlock.cid)
      check blk.tryGet() == newBlock

    test "fail getBlock":
      expect BlockNotFoundError:
        discard (await store.getBlock(newBlock.cid)).tryGet()

    test "hasBlock":
      (await store.putBlock(newBlock)).tryGet()

      check:
        (await store.hasBlock(newBlock.cid)).tryGet()
        await newBlock.cid in store

    test "fail hasBlock":
      check:
        not (await store.hasBlock(newBlock.cid)).tryGet()
        not (await newBlock.cid in store)

    test "delBlock":
      (await store.putBlock(newBlock1)).tryGet()
      check (await store.hasBlock(newBlock1.cid)).tryGet()

      (await store.delBlock(newBlock1.cid)).tryGet()

      check not (await store.hasBlock(newBlock1.cid)).tryGet()

    test "listBlocks Blocks":
      let
        blocks = @[newBlock1, newBlock2, newBlock3]

        putHandles = await allFinished(
          blocks.mapIt( store.putBlock( it ) ))

      for handle in putHandles:
        check not handle.failed
        check handle.read.isOK

      let
        cids = (await store.listBlocks(blockType = BlockType.Block)).tryGet()

      var count = 0
      for c in cids:
        if cid =? (await c):
          check (await store.hasBlock(cid)).tryGet()
          count.inc

      check count == 3

    test "listBlocks Manifest":
      let
        blocks = @[newBlock1, newBlock2, newBlock3]
        manifest = Manifest.new(blocks = blocks.mapIt( it.cid )).tryGet()
        manifestBlock = Block.new(manifest.encode().tryGet(), codec = DagPBCodec).tryGet()
        putHandles = await allFinished(
         (manifestBlock & blocks).mapIt( store.putBlock( it ) ))

      for handle in putHandles:
        check not handle.failed
        check handle.read.isOK

      let
        cids = (await store.listBlocks(blockType = BlockType.Manifest)).tryGet()

      var count = 0
      for c in cids:
        if cid =? (await c):
          check manifestBlock.cid == cid
          check (await store.hasBlock(cid)).tryGet()
          count.inc

      check count == 1

    test "listBlocks Both":
      let
        blocks = @[newBlock1, newBlock2, newBlock3]
        manifest = Manifest.new(blocks = blocks.mapIt( it.cid )).tryGet()
        manifestBlock = Block.new(manifest.encode().tryGet(), codec = DagPBCodec).tryGet()
        putHandles = await allFinished(
         (manifestBlock & blocks).mapIt( store.putBlock( it ) ))

      for handle in putHandles:
        check not handle.failed
        check handle.read.isOK

      let
        cids = (await store.listBlocks(blockType = BlockType.Both)).tryGet()

      var count = 0
      for c in cids:
        if cid =? (await c):
          check (await store.hasBlock(cid)).tryGet()
          count.inc

      check count == 4
