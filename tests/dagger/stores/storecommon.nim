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

proc testStoreCommon*(
  name: string,
  store: BlockStore,
  chunker: Chunker,
  blocks: seq[?Block]) =

  suite name:
    test "getBlocks single":
      let blk = await store.getBlock((!blocks[0]).cid)
      check blk == blocks[0]

    test "hasBlock":
      check store.hasBlock((!blocks[0]).cid)

    test "delBlocks single":
      check await store.delBlock((!blocks[0]).cid)
      check await store.delBlock((!blocks[1]).cid)
      check await store.delBlock((!blocks[2]).cid)

      check not store.hasBlock((!blocks[0]).cid)
      check not store.hasBlock((!blocks[1]).cid)
      check not store.hasBlock((!blocks[2]).cid)
