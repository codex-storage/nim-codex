import std/options

import pkg/unittest2
import pkg/libp2p

import pkg/storage/blockexchange/peers
import pkg/storage/blockexchange/peers/peerstats
import pkg/storage/blockexchange/utils
import pkg/storage/storagetypes

import ../helpers
import ../examples

const
  TestBlockSize = DefaultBlockSize.uint32
  TestBatchBytes = computeBatchSize(TestBlockSize).uint64 * TestBlockSize.uint64

suite "Peer Context Store":
  var
    store: PeerContextStore
    peerCtx: PeerContext

  setup:
    store = PeerContextStore.new()
    peerCtx = PeerContext.example
    store.add(peerCtx)

  test "Should add peer":
    check peerCtx.id in store

  test "Should remove peer":
    store.remove(peerCtx.id)
    check peerCtx.id notin store

  test "Should get peer":
    check store.get(peerCtx.id) == peerCtx

  test "Should return nil for unknown peer":
    let unknownId = PeerId.example
    check store.get(unknownId) == nil

  test "Should return correct length":
    check store.len == 1

    let peer2 = PeerContext.new(PeerId.example)
    store.add(peer2)
    check store.len == 2

    store.remove(peer2.id)
    check store.len == 1

  test "Should return peer IDs":
    let peer2 = PeerContext.new(PeerId.example)
    let peer3 = PeerContext.new(PeerId.example)
    store.add(peer2)
    store.add(peer3)

    let ids = store.peerIds
    check ids.len == 3
    check peerCtx.id in ids
    check peer2.id in ids
    check peer3.id in ids

  test "Should iterate over peers":
    let peer2 = PeerContext.new(PeerId.example)
    let peer3 = PeerContext.new(PeerId.example)
    store.add(peer2)
    store.add(peer3)

    var seenPeers: seq[PeerId]
    for peer in store:
      seenPeers.add(peer.id)

    check seenPeers.len == 3
    check peerCtx.id in seenPeers
    check peer2.id in seenPeers
    check peer3.id in seenPeers

  test "Should replace peer with same ID":
    let newPeerCtx = PeerContext.new(peerCtx.id)
    store.add(newPeerCtx)

    check store.len == 1 # Still only one peer
    check store.get(peerCtx.id) == newPeerCtx # New context replaces old

  test "Should handle contains check":
    check peerCtx.id in store
    let unknownId = PeerId.example
    check unknownId notin store

  test "Should be empty initially":
    let newStore = PeerContextStore.new()
    check newStore.len == 0
    check newStore.peerIds.len == 0

  test "Should check contains in array":
    let peers = @[peerCtx]
    check peerCtx.id in peers

    let unknownId = PeerId.example
    check unknownId notin peers

suite "PeerContext":
  test "Should create new PeerContext":
    let
      peerId = PeerId.example
      ctx = PeerContext.new(peerId)

    check ctx.id == peerId
    check ctx.stats.throughputBps().isNone

  test "Should compute optimal pipeline depth without stats":
    let
      ctx = PeerContext.new(PeerId.example)
      depth = ctx.optimalPipelineDepth(TestBatchBytes)
    check depth == DefaultRequestsPerPeer

suite "PeerPerfStats":
  test "Should create new stats":
    let stats = PeerPerfStats.new()
    check stats.throughputBps().isNone
    check stats.avgRttMicros().isNone
    check stats.totalBytes() == 0
    check stats.sampleCount() == 0

  test "Should record requests":
    var stats = PeerPerfStats.new()
    stats.recordRequest(1000, 65536)

    check stats.sampleCount() == 1
    check stats.totalBytes() == 65536

  test "Should compute average RTT":
    var stats = PeerPerfStats.new()
    stats.recordRequest(1000, 65536)
    stats.recordRequest(2000, 65536)
    stats.recordRequest(3000, 65536)

    let avgRtt = stats.avgRttMicros()
    check avgRtt.isSome
    check avgRtt.get == 2000

  test "Should limit RTT samples":
    var stats = PeerPerfStats.new()
    for i in 1 .. RttSampleCount + 5:
      stats.recordRequest(i.uint64 * 100, 1024)

    check stats.sampleCount() == RttSampleCount

  test "Should reset stats":
    var stats = PeerPerfStats.new()
    stats.recordRequest(1000, 65536)
    check stats.sampleCount() == 1

    stats.reset()

    check stats.sampleCount() == 0
    check stats.totalBytes() == 0
    check stats.throughputBps().isNone
    check stats.avgRttMicros().isNone

  test "Should compute batch size":
    check computeBatchSize(65536) > 0
    check computeBatchSize(1024) > computeBatchSize(65536)
