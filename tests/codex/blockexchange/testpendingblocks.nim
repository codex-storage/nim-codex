import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/stew/byteutils

import pkg/codex/blocktype as bt
import pkg/codex/blockexchange

import ../helpers
import ../../asynctest

checksuite "Pending Blocks":
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

checksuite "Pending Blocks - inFlight":
  var
    pendingBlocks: PendingBlocksManager
    blk: bt.Block
    addrs: BlockAddress

  setup:
    pendingBlocks = PendingBlocksManager.new()
    blk = bt.Block.new("Hello".toBytes).tryGet
    addrs = BlockAddress.init(blk.cid)
    discard pendingBlocks.getWantHandle(addrs)
  
  proc req(): BlockReq =
    pendingBlocks.blocks[addrs]

  test "Sets inFlight (single)":
    pendingBlocks.setInFlight(addrs)

    check:
      req().inFlight
    
  test "Sets inFlight (multiple)":
    pendingBlocks.setInFlight(@[addrs])

    check:
      req().inFlight
    
  test "IsInFlight":
    pendingBlocks.setInFlight(addrs)

    check:
      pendingBlocks.isInFlight(addrs)

  test "getNotInFlight":
    let
      blk2 = bt.Block.new("Hello2".toBytes).tryGet
      addrs2 = BlockAddress.init(blk2.cid)

    pendingBlocks.setInFlight(addrs)

    check:
      pendingBlocks.getNotInFlight(@[addrs, addrs2]) == @[addrs2]
