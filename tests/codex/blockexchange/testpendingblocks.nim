import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/stew/byteutils

import pkg/codex/blocktype as bt
import pkg/codex/blockexchange

import ../helpers
import ../../asynctest

suite "Pending Blocks":
  test "Should add want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet

    discard pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks

  test "Should resolve want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle = pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks
    pendingBlocks.resolve(@[blk].mapIt(BlockDelivery(blk: it, address: it.address)))
    await sleepAsync(0.millis)
      # trigger the event loop, otherwise the block finishes before poll runs
    let resolved = await handle
    check resolved == blk
    check blk.cid notin pendingBlocks

  test "Should cancel want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle = pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks
    await handle.cancelAndWait()
    check blk.cid notin pendingBlocks

  test "Should get wants list":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0 .. 9).mapIt(bt.Block.new(("Hello " & $it).toBytes).tryGet)

    discard blks.mapIt(pendingBlocks.getWantHandle(it.cid))

    check:
      blks.mapIt($it.cid).sorted(cmp[string]) ==
        toSeq(pendingBlocks.wantListBlockCids).mapIt($it).sorted(cmp[string])

  test "Should get want handles list":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0 .. 9).mapIt(bt.Block.new(("Hello " & $it).toBytes).tryGet)
      handles = blks.mapIt(pendingBlocks.getWantHandle(it.cid))
      wantHandles = toSeq(pendingBlocks.wantHandles)

    check wantHandles.len == handles.len
    pendingBlocks.resolve(blks.mapIt(BlockDelivery(blk: it, address: it.address)))

    check:
      (await allFinished(wantHandles)).mapIt($it.read.cid).sorted(cmp[string]) ==
        (await allFinished(handles)).mapIt($it.read.cid).sorted(cmp[string])

  test "Should handle retry counters":
    let
      pendingBlocks = PendingBlocksManager.new(3)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      handle = pendingBlocks.getWantHandle(blk.cid)

    check pendingBlocks.retries(address) == 3
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 2
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 1
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 0
    check pendingBlocks.retriesExhausted(address)
