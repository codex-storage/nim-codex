import std/[sequtils, algorithm, options]

import pkg/chronos
import pkg/stew/byteutils
import pkg/libp2p/peerid
import pkg/libp2p/cid

import pkg/storage/merkletree
import pkg/storage/blocktype as bt
import pkg/storage/blockexchange
import pkg/storage/blockexchange/engine/downloadcontext {.all.}
import pkg/storage/blockexchange/engine/activedownload {.all.}
import pkg/storage/blockexchange/engine/downloadmanager {.all.}
import pkg/storage/blockexchange/engine/scheduler {.all.}
import pkg/storage/blockexchange/engine/swarm
import pkg/storage/storagetypes

import ../helpers
import ../examples
import ../../asynctest

const
  WindowSize = 16384'u64
  Threshold = 0.75

suite "DownloadManager - Want Handles":
  test "Should add want handle":
    let
      downloadManager = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = downloadManager.startDownload(desc)

    discard download.getWantHandle(address)

    check address in download

  test "Should resolve want handle":
    let
      downloadManager = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = downloadManager.startDownload(desc)
      handle = download.getWantHandle(address)

    check address in download
    discard download.completeWantHandle(address, some(blk))
    let resolved = (await handle).tryGet
    check resolved == blk

  test "Should cancel want handle":
    let
      downloadManager = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = downloadManager.startDownload(desc)
      handle = download.getWantHandle(address)

    check address in download
    await handle.cancelAndWait()
    check address notin download

  test "Should handle retry counters":
    let
      dm = DownloadManager.new(3)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = dm.startDownload(desc)

    discard download.getWantHandle(address)

    check download.retries(address) == 3
    download.decRetries(address)
    check download.retries(address) == 2
    download.decRetries(address)
    check download.retries(address) == 1
    download.decRetries(address)
    check download.retries(address) == 0
    check download.retriesExhausted(address)

asyncchecksuite "DownloadManager - Download Lifecycle":
  test "Should start new download":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)

    let download = dm.startDownload(desc)

    check download.cid == treeCid

  test "Should allow multiple downloads for same CID":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      download1 = dm.startDownload(desc)
      download2 = dm.startDownload(desc)

    check download1.id != download2.id
    check download1.cid == download2.cid

  test "Multiple downloads for same CID have independent block state":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)

      download1 = dm.startDownload(desc)
      download2 = dm.startDownload(desc)

      address = BlockAddress(treeCid: treeCid, index: 0)
      handle1 = download1.getWantHandle(address)

    check address in download1
    check address notin download2

    let blk = bt.Block.new("test data".toBytes).tryGet()
    discard download1.completeWantHandle(address, some(blk))

    let res = await handle1
    check res.isOk

    check address notin download2

  test "Cancel one download for same CID while other continues":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      download1 = dm.startDownload(desc)
      download2 = dm.startDownload(desc)
      address = BlockAddress(treeCid: treeCid, index: 0)

    discard download1.getWantHandle(address)
    let handle2 = download2.getWantHandle(address)

    dm.cancelDownload(download1)

    check download1.cancelled == true
    check download2.cancelled == false

    let blk = bt.Block.new("test data".toBytes).tryGet()
    discard download2.completeWantHandle(address, some(blk))

    let res = await handle2
    check res.isOk

    check dm.getDownload(download2.id, treeCid).isSome
    check dm.getDownload(download1.id, treeCid).isNone

  test "Should start range download":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 50'u64, 100'u64, 65536)
      download = dm.startDownload(desc)

    check download.ctx.totalBlocks == 150 # 50 + 100

  test "Should start download with missing blocks":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      missingBlocks = @[10'u64, 11, 12, 50, 51, 100]
      download = dm.startDownload(desc, missingBlocks)

    check download.ctx.scheduler.hasWork() == true

  test "Should release download":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)

    discard dm.startDownload(desc)

    dm.releaseDownload(treeCid)
    check dm.getDownload(treeCid).isNone

  test "Should cancel download":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)

    discard dm.startDownload(desc)

    dm.cancelDownload(treeCid)

    check dm.getDownload(treeCid).isNone

  test "Should return none for non-existent download":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example

    check dm.getDownload(treeCid).isNone

  test "Should set cancelled flag when download is cancelled":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)

    let downloadBefore = dm.startDownload(desc)

    check downloadBefore.cancelled == false

    dm.cancelDownload(treeCid)

    check dm.getDownload(treeCid).isNone

    check downloadBefore.cancelled == true

  test "Should allow new download for same CID after cancellation":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      oldDownload = dm.startDownload(desc)

    dm.cancelDownload(treeCid)
    check oldDownload.cancelled == true

    let newDownload = dm.startDownload(desc)

    check newDownload.cancelled == false
    check newDownload != oldDownload

    check oldDownload.cancelled == true

  test "Should set cancelled flag when released":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      downloadRef = dm.startDownload(desc)

    check downloadRef.cancelled == false

    dm.releaseDownload(treeCid)

    check dm.getDownload(treeCid).isNone

    check downloadRef.cancelled == true

suite "DownloadManager - Batch Management":
  test "Should get next batch":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome
    check batch.get.start == 0

  test "Should mark batch in flight":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.markBatchInFlight(batch.get.start, batch.get.count, 0, peerId)

    check download.pendingBatches.len == 1
    check batch.get.start in download.pendingBatches

  test "Should complete batch":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.markBatchInFlight(batch.get.start, batch.get.count, 0, peerId)
    download.completeBatch(batch.get.start, 0, 0)

    check download.pendingBatches.len == 0

  test "Should requeue batch at back":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch1 = dm.getNextBatch(download)

    download.markBatchInFlight(batch1.get.start, batch1.get.count, 0, peerId)

    let batch2 = dm.getNextBatch(download)
    download.markBatchInFlight(batch2.get.start, batch2.get.count, 0, peerId)

    download.requeueBatch(batch1.get.start, batch1.get.count, front = false)

    check download.pendingBatches.len == 1
    check download.ctx.scheduler.requeuedCount() == 1

  test "Should requeue batch at front":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch1 = dm.getNextBatch(download)

    download.markBatchInFlight(batch1.get.start, batch1.get.count, 0, peerId)

    download.requeueBatch(batch1.get.start, batch1.get.count, front = true)

    let nextBatch = dm.getNextBatch(download)
    check nextBatch.isSome
    check nextBatch.get.start == batch1.get.start

  test "Should handle partial batch completion":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.markBatchInFlight(batch.get.start, batch.get.count, 0, peerId)

    let missingRanges = @[(start: 50'u64, count: 50'u64)]
    download.partialCompleteBatch(batch.get.start, batch.get.count, 0, missingRanges, 0)

    check download.ctx.scheduler.requeuedCount() >= 1

suite "DownloadManager - Download Status":
  test "Should check if download is complete":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 10, 65536)
      download = dm.startDownload(desc)

    check download.isDownloadComplete() == false

    download.ctx.received = 10

    check download.isDownloadComplete() == true

  test "Should check if work remains":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      download = dm.startDownload(desc)

    check download.hasWorkRemaining() == true

  test "Should return pending batch count":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      peerId = PeerId.example
      download = dm.startDownload(desc)

    check download.pendingBatchCount() == 0

    let batch = dm.getNextBatch(download)
    download.markBatchInFlight(batch.get.start, batch.get.count, 0, peerId)

    check download.pendingBatchCount() == 1

suite "DownloadManager - Peer Management":
  test "Should handle peer failure":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch1 = dm.getNextBatch(download)

    download.markBatchInFlight(batch1.get.start, batch1.get.count, 0, peerId)

    let batch2 = dm.getNextBatch(download)
    download.markBatchInFlight(batch2.get.start, batch2.get.count, 0, peerId)

    check download.pendingBatchCount() == 2

    download.handlePeerFailure(peerId)

    check download.pendingBatchCount() == 0
    check download.ctx.scheduler.requeuedCount() == 2

  test "Should get swarm":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      download = dm.startDownload(desc)
      swarm = download.getSwarm()
    check swarm != nil

  test "Should update peer availability - add new peer":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      peerId = PeerId.example
      availability = BlockAvailability.complete()
      download = dm.startDownload(desc)

    download.updatePeerAvailability(peerId, availability)

    let
      swarm = download.getSwarm()
      peer = swarm.getPeer(peerId)
    check peer.isSome
    check peer.get.availability.kind == bakComplete

  test "Should update peer availability - update existing peer":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      peerId = PeerId.example
      download = dm.startDownload(desc)

    download.updatePeerAvailability(peerId, BlockAvailability.unknown())

    let peerBefore = download.getSwarm().getPeer(peerId)
    check peerBefore.get.availability.kind == bakUnknown

    download.updatePeerAvailability(peerId, BlockAvailability.complete())

    let peerAfter = download.getSwarm().getPeer(peerId)
    check peerAfter.get.availability.kind == bakComplete

suite "DownloadManager - Retry Management":
  test "Should decrement block retries":
    let
      dm = DownloadManager.new(retries = 5)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = dm.startDownload(desc)

    discard download.getWantHandle(address)

    check download.retries(address) == 5

    let exhausted = download.decrementBlockRetries(@[address])
    check exhausted.len == 0
    check download.retries(address) == 4

  test "Should return exhausted blocks":
    let
      dm = DownloadManager.new(retries = 2)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = dm.startDownload(desc)

    discard download.getWantHandle(address)

    discard download.decrementBlockRetries(@[address])
    check download.retries(address) == 1

    let exhausted = download.decrementBlockRetries(@[address])
    check exhausted.len == 1
    check address in exhausted

  test "Should fail exhausted blocks":
    let
      dm = DownloadManager.new(retries = 1)
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      address = BlockAddress(treeCid: treeCid, index: 0)
      download = dm.startDownload(desc)

    discard download.getWantHandle(address)
    discard download.decrementBlockRetries(@[address])

    download.failExhaustedBlocks(@[address])

    check download.isBlockExhausted(address) == true
    check address notin download

  test "Should get block addresses for range":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      download = dm.startDownload(desc)

    for i in 0'u64 ..< 5:
      let address = BlockAddress(treeCid: treeCid, index: i.int)
      discard download.getWantHandle(address)

    let addresses = download.getBlockAddressesForRange(0, 10)
    check addresses.len == 5

suite "DownloadManager - Request Tracking":
  test "Should mark block as requested":
    let
      dm = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = dm.startDownload(desc)
      peerId = PeerId.example

    discard download.getWantHandle(address)

    check download.isRequested(address) == false

    let marked = download.markRequested(address, peerId)
    check marked == true
    check download.isRequested(address) == true
    check download.getRequestPeer(address) == some(peerId)

  test "Should not mark already requested block":
    let
      dm = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = dm.startDownload(desc)
      peer1 = PeerId.example
      peer2 = PeerId.example

    discard download.getWantHandle(address)

    let marked1 = download.markRequested(address, peer1)
    check marked1 == true

    let marked2 = download.markRequested(address, peer2)
    check marked2 == false
    check download.getRequestPeer(address) == some(peer1) # Still first peer

  test "Should clear request":
    let
      dm = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      desc = toDownloadDesc(address, DefaultBlockSize.uint32)
      download = dm.startDownload(desc)
      peerId = PeerId.example

    discard download.getWantHandle(address)
    discard download.markRequested(address, peerId)

    download.clearRequest(address)

    check download.isRequested(address) == false
    check download.getRequestPeer(address).isNone

suite "DownloadManager - DownloadDesc":
  test "Should create full tree download desc":
    let
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 1000, 65536)

    check desc.cid == treeCid

    check desc.startIndex == 0
    check desc.count == 1000
    check desc.id == treeCid

  test "Should create range download desc":
    let
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 500, 200, 65536)

    check desc.cid == treeCid

    check desc.startIndex == 500
    check desc.count == 200

  test "Should create leaf block download desc from address":
    let
      treeCid = Cid.example
      address = BlockAddress(treeCid: treeCid, index: 42)
      desc = toDownloadDesc(address, 65536)

    check desc.cid == treeCid

    check desc.startIndex == 42
    check desc.count == 1

suite "DownloadContext - Basics":
  test "Should create download context":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 1000, 65536))

    check ctx.treeCid == treeCid
    check ctx.blockSize == 65536
    check ctx.totalBlocks == 1000
    check ctx.received == 0
    check ctx.bytesReceived == 0

  test "Should report not complete initially":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))

    check ctx.isComplete() == false

  test "Should report complete when all received":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))

    ctx.received = 100

    check ctx.isComplete() == true

  test "Should return progress":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))

    ctx.received = 50
    ctx.bytesReceived = 50'u64 * 65536

    let progress = ctx.progress()
    check progress.blocksCompleted == 50
    check progress.totalBlocks == 100
    check progress.bytesTransferred == 50'u64 * 65536

  test "Should return remaining blocks":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))

    check ctx.remainingBlocks() == 100

    ctx.received = 60
    check ctx.remainingBlocks() == 40

    ctx.received = 100
    check ctx.remainingBlocks() == 0

  test "Should init scheduler with missing blocks":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 1000, 65536))
      missingBlocks = @[10'u64, 11, 12, 50, 51, 100]

    ctx.scheduler.initFromIndices(missingBlocks, 256, WindowSize, Threshold)

    check ctx.scheduler.hasWork() == true

  test "Should mark batch received":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))
      peerId = PeerId.example

    ctx.markBatchInFlight(0, 10, peerId)
    check ctx.inFlightCount() == 10

    ctx.markBatchReceived(0, 10, 10'u64 * 65536)

    check ctx.received == 10
    check ctx.bytesReceived == 10'u64 * 65536
    check ctx.inFlightCount() == 0

  test "Should mark block in flight":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))
      peerId = PeerId.example

    ctx.markBlockInFlight(42, peerId)

    check ctx.isBlockInFlight(42) == true
    check ctx.isBlockInFlight(43) == false
    check ctx.inFlightCount() == 1

  test "Should mark batch in flight":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))
      peerId = PeerId.example

    ctx.markBatchInFlight(10, 5, peerId)

    for i in 10'u64 ..< 15:
      check ctx.isBlockInFlight(i) == true
    check ctx.isBlockInFlight(15) == false
    check ctx.inFlightCount() == 5

  test "Should clear in-flight for peer":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))
      peer1 = PeerId.example
      peer2 = PeerId.example

    ctx.markBatchInFlight(0, 5, peer1)
    ctx.markBatchInFlight(10, 5, peer2)

    check ctx.inFlightCount() == 10

    ctx.clearInFlightForPeer(peer1)

    check ctx.inFlightCount() == 5
    for i in 0'u64 ..< 5:
      check ctx.isBlockInFlight(i) == false
    for i in 10'u64 ..< 15:
      check ctx.isBlockInFlight(i) == true

suite "DownloadContext - Windowed Presence":
  test "Should compute presence window size":
    check computeWindowSize(65536) == 1024'u64 * 1024 * 1024 div 65536
    check computeWindowSize(1024) == 1024'u64 * 1024 * 1024 div 1024
    check computeWindowSize(2'u32 * 1024 * 1024 * 1024) >= 1'u64

  test "Should initialize presence window":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100000, 65536))
      window = ctx.currentPresenceWindow()

    check window.start == 0
    check window.count > 0

  test "Should get current presence window":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100000, 65536))
      window = ctx.currentPresenceWindow()

    check window.start == 0
    check window.count > 0

  test "Should check if block is in presence window":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100000, 65536))
      window = ctx.currentPresenceWindow()

    check 0'u64 >= window.start and 0'u64 < window.start + window.count
    check window.start + window.count - 1 >= window.start
    check not (
      window.start + window.count >= window.start and
      window.start + window.count < window.start + window.count
    )

  test "Should advance presence window":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100000, 65536))
      oldWindow = ctx.currentPresenceWindow()
      oldEnd = oldWindow.start + oldWindow.count
      advancedWindow = ctx.advancePresenceWindow()

    check advancedWindow.start == oldEnd
    check advancedWindow.start + advancedWindow.count > oldEnd

  test "Should check if needs next presence window":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100000, 65536))

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)
    check ctx.needsNextPresenceWindow() == false

    let
      window = ctx.currentPresenceWindow()
      windowEnd = window.start + window.count
      threshold = (windowEnd.float * 0.75).uint64

    var pos: uint64 = 0
    while pos < windowEnd:
      discard ctx.scheduler.take()
      pos += 256

    pos = 0
    while pos <= threshold:
      ctx.scheduler.markComplete(pos)
      pos += 256

    if windowEnd < ctx.totalBlocks:
      check ctx.needsNextPresenceWindow() == true

  test "Should not need next window when at last window":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100, 65536))
        # Small total, fits in one window

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)

    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(0)
    check ctx.needsNextPresenceWindow() == false

  test "Should trim ranges entirely below watermark":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100000, 65536))
      peerId = PeerId.example
      ranges = @[(start: 0'u64, count: 400'u64), (start: 2000'u64, count: 500'u64)]

    discard ctx.swarm.addPeer(peerId, BlockAvailability.fromRanges(ranges))

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(0)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(256)

    ctx.trimPresenceBeforeWatermark()

    let peer = ctx.swarm.getPeer(peerId)
    check peer.isSome
    check peer.get.availability.kind == bakRanges
    check peer.get.availability.ranges.len == 1
    check peer.get.availability.ranges[0].start == 2000
    check peer.get.availability.ranges[0].count == 500

  test "Should keep ranges spanning the watermark intact":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100000, 65536))
      peerId = PeerId.example
      ranges = @[(start: 0'u64, count: 1000'u64)]
    discard ctx.swarm.addPeer(peerId, BlockAvailability.fromRanges(ranges))

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(0)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(256)

    ctx.trimPresenceBeforeWatermark()

    let peer = ctx.swarm.getPeer(peerId)
    check peer.isSome
    check peer.get.availability.kind == bakRanges
    check peer.get.availability.ranges.len == 1
    check peer.get.availability.ranges[0].start == 0
    check peer.get.availability.ranges[0].count == 1000

  test "Should not trim bakComplete peers":
    let
      treeCid = Cid.example
      ctx = DownloadContext.new(toDownloadDesc(treeCid, 100000, 65536))
      peerId = PeerId.example

    discard ctx.swarm.addPeer(peerId, BlockAvailability.complete())

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(0)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(256)

    ctx.trimPresenceBeforeWatermark()

    let peer = ctx.swarm.getPeer(peerId)
    check peer.isSome
    check peer.get.availability.kind == bakComplete

suite "DownloadManager - Completion Future":
  test "Should complete batch locally":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 10, 65536)
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.completeBatchLocal(batch.get.start, batch.get.count)

    check download.ctx.scheduler.isEmpty()
    check download.ctx.received == 10
    check download.ctx.bytesReceived == 0
    check download.pendingBatches.len == 0
    check download.ctx.isComplete()

  test "Should resolve completion future on success":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 10, 65536)
      download = dm.startDownload(desc)

    check not download.completionFuture.finished

    let batch = dm.getNextBatch(download)
    check batch.isSome

    download.completeBatchLocal(batch.get.start, batch.get.count)

    check download.completionFuture.finished
    check not download.completionFuture.failed
    let res = await download.waitForComplete()
    check res.isOk

  test "Should resolve completion future with error on exhausted blocks":
    let
      dm = DownloadManager.new(retries = 1)
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 10, 65536)
      download = dm.startDownload(desc)

    var addresses: seq[BlockAddress] = @[]
    for i in 0'u64 ..< 10:
      let address = BlockAddress(treeCid: treeCid, index: i.int)
      discard download.getWantHandle(address)
      addresses.add(address)

    discard download.decrementBlockRetries(addresses)

    download.failExhaustedBlocks(addresses)

    check download.completionFuture.finished
    check not download.completionFuture.failed
    let res = await download.waitForComplete()
    check res.isErr
    check res.error of RetriesExhaustedError

  test "Should fail completion future on cancel":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 100, 65536)
      download = dm.startDownload(desc)

    check not download.completionFuture.finished

    dm.cancelDownload(treeCid)

    check download.completionFuture.finished
    check download.completionFuture.failed

  test "Should not double-complete completion future":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 10, 65536)
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.completeBatchLocal(batch.get.start, batch.get.count)

    check download.completionFuture.finished
    check not download.completionFuture.failed
    let result1 = await download.waitForComplete()
    check result1.isOk

    let error = (ref RetriesExhaustedError)(msg: "test error")
    download.signalCompletionIfDone(error)

    check not download.completionFuture.failed
    let result2 = await download.waitForComplete()
    check result2.isOk

  test "Should propagate error through waitForComplete async":
    let
      dm = DownloadManager.new(retries = 1)
      treeCid = Cid.example
      desc = toDownloadDesc(treeCid, 10, 65536)
      download = dm.startDownload(desc)
      waiter = download.waitForComplete()

    check not waiter.finished

    var addresses: seq[BlockAddress] = @[]
    for i in 0'u64 ..< 10:
      let address = BlockAddress(treeCid: treeCid, index: i.int)
      discard download.getWantHandle(address)
      addresses.add(address)

    discard download.decrementBlockRetries(addresses)
    download.failExhaustedBlocks(addresses)

    let res = await waiter
    check res.isErr
    check res.error of RetriesExhaustedError
