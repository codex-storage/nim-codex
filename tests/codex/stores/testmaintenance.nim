## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/chronicles
import pkg/asynctest

import ../helpers/mocktimer
import ../helpers/mockblockstore

import codex/stores/maintenance

suite "BlockMaintainer":
  var mockBlockStore: MockBlockStore
  var interval: Duration
  var mockTimer: MockTimer
  # var mockBlockChecker: MockBlockChecker

  var blockMaintainer: BlockMaintainer

  setup:
    interval = 1.days
    mockTimer = MockTimer.new()

    blockMaintainer = BlockMaintainer.new(
      mockBlockStore,
      interval,
      mockTimer
      # mockBlockChecker
    )

  test "Start should start timer at provided interval":
    blockMaintainer.start()

    check mockTimer.startCalled == 1


