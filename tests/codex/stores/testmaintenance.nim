## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p
import pkg/asynctest
import pkg/questionable
import pkg/questionable/results
import pkg/codex/blocktype as bt

import ../helpers/mocktimer
import ../helpers/mockblockstore
import ../helpers/mockblockchecker
import ../examples

import codex/stores/maintenance

suite "BlockMaintainer":
  var mockBlockStore: MockBlockStore
  var interval: Duration
  var mockTimer: MockTimer[BlockMaintainer]
  var mockBlockChecker: MockBlockChecker

  var blockMaintainer: BlockMaintainer

  let testBlock1 = bt.Block.example

  setup:
    mockBlockStore = MockBlockStore.new()
    interval = 1.days
    mockTimer = MockTimer[BlockMaintainer].new()
    mockBlockChecker = MockBlockChecker.new()

    blockMaintainer = BlockMaintainer.new(
      mockBlockStore,
      interval,
      mockTimer,
      mockBlockChecker
    )

  test "Start should start timer at provided interval":
    blockMaintainer.start()
    check mockTimer.startCalled == 1

  # test "Stop should stop timer":
  #   await blockMaintainer.stop()
  #   check mockTimer.stopCalled == 1

  # test "Timer callback should get and check first block in blockstore":
  #   mockBlockStore.testBlocks.add(testBlock1)

  #   blockMaintainer.start()
  #   await mockTimer.invokeCallback()

  #   check mockBlockChecker.receivedBlockStore == mockBlockStore
  #   check mockBlockChecker.checkCalls == [testBlock1.cid]
