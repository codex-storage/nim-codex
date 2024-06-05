## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/random

import pkg/chronos
import pkg/questionable/results
import pkg/codex/blocktype
import pkg/codex/stores
import pkg/codex/clock
import pkg/codex/rng
import pkg/datastore

import ../../asynctest
import ../helpers
import ../helpers/mocktimer
import ../helpers/mockclock
import ../examples

import codex/stores/maintenance

asyncchecksuite "DatasetMaintainer":

  var
    clock: MockClock
    timer: MockTimer
    metaDs: Datastore
    blockStore: BlockStore
    maintenance: DatasetMaintainer

  setup:
    clock = MockClock.new()
    timer = MockTimer.new()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    blockStore = RepoStore.new(metaDs, metaDs)
    maintenance = DatasetMaintainer.new(
      blockStore = blockStore,
      metaDs = metaDs,
      timer = timer,
      clock = clock,
      defaultExpiry = 100.seconds,
      interval = 10.seconds,
      restartDelay = 10.seconds
    )

    maintenance.start()
    clock.set(0)

  teardown:
    await maintenance.stop()

  proc listStoredBlocks(manifest: Manifest): Future[seq[int]] {.async.} =
    var indicies = newSeq[int]()

    for i in 0..<manifest.blocksCount:
      let address = BlockAddress.init(manifest.treeCid, i)
      if (await address in blockStore):
        indicies.add(i)

    indicies

  test "Should not delete dataset":
    let manifest = await storeDataGetManifest(blockStore, blocksCount = 5)
    (await maintenance.trackExpiry(manifest.treeCid, 100.SecondsSince1970, @[Cid.example])).tryGet()

    clock.advance(50)

    await timer.invokeCallback()
    await sleepAsync(1.seconds)

    check:
      @[0, 1, 2, 3, 4] == await listStoredBlocks(manifest)

  test "Should delete expired dataset":
    let manifest = await storeDataGetManifest(blockStore, blocksCount = 5)
    (await maintenance.trackExpiry(manifest.treeCid, 100.SecondsSince1970, @[Cid.example])).tryGet()

    clock.advance(150)

    await timer.invokeCallback()
    await sleepAsync(1.seconds)

    check:
      newSeq[int]() == await listStoredBlocks(manifest)

  test "Should not delete dataset with prolonged expiry":
    let manifest = await storeDataGetManifest(blockStore, blocksCount = 5)
    (await maintenance.trackExpiry(manifest.treeCid, 100.SecondsSince1970, @[Cid.example])).tryGet()
    (await maintenance.ensureExpiry(manifest.treeCid, 200.SecondsSince1970)).tryGet()

    clock.advance(150)

    await timer.invokeCallback()
    await sleepAsync(1.seconds)

    check:
      @[0, 1, 2, 3, 4] == await listStoredBlocks(manifest)

  test "Should delete dataset without prolonged expiry":
    let manifest = await storeDataGetManifest(blockStore, blocksCount = 5)
    (await maintenance.trackExpiry(manifest.treeCid, 100.SecondsSince1970, @[Cid.example])).tryGet()
    (await maintenance.ensureExpiry(manifest.treeCid, 100.SecondsSince1970)).tryGet()

    clock.advance(150)

    await timer.invokeCallback()
    await sleepAsync(1.seconds)

    check:
      newSeq[int]() == await listStoredBlocks(manifest)

  test "Should find correct number of leaves/blocks":
    let 
      storedLeavesCount = rand(10..1000)
      manifest = await storeDataGetManifest(blockStore, blocksCount = storedLeavesCount)

    let leavesCount = (await maintenance.findLeavesCount(manifest.treeCid)).tryGet()

    check:
      leavesCount == storedLeavesCount
