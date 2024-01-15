import std/sequtils

import pkg/chronos
import pkg/asynctest
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/indexingstrategy
import pkg/codex/proof/slotblocks
import pkg/codex/utils/asynciter

import ../helpers
import ../merkletree/helpers
import ./provingtestenv

asyncchecksuite "Test slotblocks":
  var
    env: ProvingTestEnvironment
    slotBlocks: SlotBlocks

  proc createSlotBlocks(): Future[void] {.async.} =
    slotBlocks = SlotBlocks.new(
      env.slot.slotIndex,
      env.slot.request.content.cid,
      env.localStore)
    (await slotBlocks.start()).tryGet()

  proc createSlotBlocks(store: BlockStore): Future[?!SlotBlocks] {.async.} =
    let sb = SlotBlocks.new(
      env.slot.slotIndex,
      env.slot.request.content.cid,
      store)
    if err =? (await sb.start()).errorOption:
      return failure(err)
    return success(sb)

  setup:
    env = await createProvingTestEnvironment()
    await createSlotBlocks()

  teardown:
    reset(env)
    reset(slotBlocks)

  test "Can get manifest for slot":
    let m = slotBlocks.manifest

    check:
      m.treeCid == env.manifest.treeCid

  test "Can fail to get manifest for invalid cid":
    env.slot.request.content.cid = "invalid"
    let s = await createSlotBlocks(env.localStore)

    check:
      s.isErr

  test "Can fail to get manifest when manifest block not found":
    let
      emptyStore = CacheStore.new()
      s = await createSlotBlocks(emptyStore)

    check:
      s.isErr

  test "Can fail to get manifest when manifest fails to decode":
    env.manifestBlock.data = @[]

    let s = await createSlotBlocks(env.localStore)

    check:
      s.isErr

  for input in 0 ..< numberOfSlotBlocks:
    test "Can get datasetBlockIndex from slotBlockIndex (" & $input & ")":
      let
        strategy = SteppedIndexingStrategy.new(0, env.manifest.blocksCount - 1, totalNumberOfSlots)
        slotBlockIndex = input.uint64
        datasetBlockIndex = slotBlocks.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex).tryGet()
        datasetSlotIndex = env.slot.slotIndex.truncate(uint64)
        expectedIndex = toSeq(strategy.getIndicies(datasetSlotIndex.int))[slotBlockIndex]

      check:
        datasetBlockIndex == expectedIndex

  for input in [0, 1, numberOfSlotBlocks-1]:
    test "Can get slot block by index (" & $input & ")":
      let
        slotBlockIndex = input.uint64
        slotBlock = (await slotBlocks.getSlotBlock(slotBlockIndex)).tryget()
        expectedDatasetBlockIndex = slotBlocks.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex).tryGet()
        expectedBlock = env.datasetBlocks[expectedDatasetBlockIndex]

      check:
        slotBlock.cid == expectedBlock.cid
        slotBlock.data == expectedBlock.data

  test "Can fail to get block when index is out of range":
    let
      b1 = await slotBlocks.getSlotBlock(numberOfSlotBlocks.uint64)
      b2 = await slotBlocks.getSlotBlock((numberOfSlotBlocks + 1).uint64)

    check:
      b1.isErr
      b2.isErr
