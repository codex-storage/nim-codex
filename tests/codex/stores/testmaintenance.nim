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
import pkg/codex/clock

import ../helpers/mocktimer
import ../helpers/mockrepostore
import ../helpers/mockblockchecker
import ../helpers/mockclock
import ../examples

import codex/stores/maintenance

suite "BlockMaintainer":
  var mockRepoStore: MockRepoStore
  var interval: Duration
  var mockTimer: MockTimer
  var mockClock: MockClock

  var blockMaintainer: BlockMaintainer

  let testBe1 = BlockExpiration
  let testBe2 = BlockExpiration
  let testBe3 = BlockExpiration

  proc createTestExpiration(expiration: SecondsSince1970): BlockExpiration =
    BlockExpiration(
      cid: bt.Block.example.cid
      expiration: expiration
    )

  setup:
    mockClock = MockClock.new()
    mockClock.set(100)

    testBe1 = createTestExpiration(200)
    testBe2 = createTestExpiration(300)
    testBe3 = createTestExpiration(400)

    mockRepoStore = MockRepoStore.new()
    mockRepoStore.testBlockExpirations.add(testBe1)
    mockRepoStore.testBlockExpirations.add(testBe2)
    mockRepoStore.testBlockExpirations.add(testBe3)

    interval = 1.days
    mockTimer = MockTimer.new()

    blockMaintainer = BlockMaintainer.new(
      mockRepoStore,
      interval,
      mockTimer,
      mockClock,
      numberOfBlocksPerInterval = 2
    )

  test "Start should start timer at provided interval":
    blockMaintainer.start()
    check mockTimer.startCalled == 1
    check mockTimer.mockInterval == interval

  test "Stop should stop timer":
    await blockMaintainer.stop()
    check mockTimer.stopCalled == 1

  test "Timer callback should call getBlockExpirations on RepoStore":
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.getBeMaxNumer == 2
      mockRepoStore.getBeOffset == 0

  test "Subsequent timer callback should call getBlockExpirations on RepoStore with offset":
    blockMaintainer.start()
    await mockTimer.invokeCallback()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.getBeMaxNumer == 2
      mockRepoStore.getBeOffset == 2

  test "Timer callback should delete no blocks if none are expired":
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.delBlockCids.len == 0

  test "Timer callback should delete one block if it is expired":
    mockClock.set(150)
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.delBlockCids == [testBe1.cid]

  test "Timer callback should delete multiple blocks if they are expired":
    mockClock.set(500)
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.delBlockCids == [testBe1.cid, testBe2.cid, testBe3.cid]

  test "After deleting a block, subsequent timer callback should decrease offset by the number of deleted blocks":
    mockClock.set(250)
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check mockRepoStore.delBlockCids == [testBe1.cid]

    # Because one block was deleted, the offset used in the next call should be 2 minus 1.
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.getBeMaxNumer == 2
      mockRepoStore.getBeOffset == 1

