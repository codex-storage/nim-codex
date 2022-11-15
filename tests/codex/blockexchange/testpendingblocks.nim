import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils

import pkg/codex/blocktype as bt
import pkg/codex/blockexchange

import ../examples

suite "Pending Blocks":
  test "Should add want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle = pendingBlocks.getWantHandle(blk.cid)

    check pendingBlocks.pending(blk.cid)

  test "Should resolve want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle = pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks
    pendingBlocks.resolve(@[blk])
    check (await handle) == blk
    check blk.cid notin pendingBlocks

  test "Should cancel want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle = pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks
    await handle.cancelAndWait()
    check blk.cid notin pendingBlocks

  test "Should expire want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle = pendingBlocks.getWantHandle(blk.cid, 1.millis)

    check blk.cid in pendingBlocks

    await sleepAsync(10.millis)
    expect AsyncTimeoutError:
      discard await handle

    check blk.cid notin pendingBlocks

  test "Should get wants list":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0..9).mapIt( bt.Block.new(("Hello " & $it).toBytes).tryGet )
      handles = blks.mapIt( pendingBlocks.getWantHandle( it.cid ) )

    check:
      blks.mapIt( $it.cid ).sorted(cmp[string]) ==
      toSeq(pendingBlocks.wantList).mapIt( $it ).sorted(cmp[string])

  test "Should get want handles list":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0..9).mapIt( bt.Block.new(("Hello " & $it).toBytes).tryGet )
      handles = blks.mapIt( pendingBlocks.getWantHandle( it.cid ) )
      wantHandles = toSeq(pendingBlocks.wantHandles)

    check wantHandles.len == handles.len
    pendingBlocks.resolve(blks)

    check:
      (await allFinished(wantHandles)).mapIt( $it.read.cid ).sorted(cmp[string]) ==
      (await allFinished(handles)).mapIt( $it.read.cid ).sorted(cmp[string])
