import pkg/unittest2
import pkg/chronos
import pkg/libp2p/peerid

import pkg/storage/blockexchange/engine/peertracker

import ../../examples

suite "PeerInFlightTracker":
  var tracker: PeerInFlightTracker
  var peerA, peerB: PeerId

  setup:
    tracker = PeerInFlightTracker.new()
    peerA = PeerId.example
    peerB = PeerId.example

  test "count returns 0 for unknown peer":
    check tracker.count(peerA) == 0

  test "count reflects tracked futures":
    tracker.track(peerA, newFuture[void]())
    tracker.track(peerA, newFuture[void]())
    check tracker.count(peerA) == 2

  test "count is per-peer":
    tracker.track(peerA, newFuture[void]())
    tracker.track(peerB, newFuture[void]())
    tracker.track(peerB, newFuture[void]())
    check tracker.count(peerA) == 1
    check tracker.count(peerB) == 2

  test "count filters finished futures (lazy cleanup)":
    let done = newFuture[void]()
    let live = newFuture[void]()
    tracker.track(peerA, done)
    tracker.track(peerA, live)
    done.complete()

    check tracker.count(peerA) == 1

  test "count removes peer entry when all futures finish":
    let fut = newFuture[void]()
    tracker.track(peerA, fut)
    fut.complete()

    check tracker.count(peerA) == 0
    check peerA notin tracker.peerInFlight

  test "track accumulates across calls from different owners":
    let downloadAFut = newFuture[void]()
    let downloadBFut = newFuture[void]()
    tracker.track(peerA, downloadAFut)
    tracker.track(peerA, downloadBFut)

    check tracker.count(peerA) == 2

  test "clearPeer removes all entries for peer":
    tracker.track(peerA, newFuture[void]())
    tracker.track(peerA, newFuture[void]())
    tracker.track(peerB, newFuture[void]())

    tracker.clearPeer(peerA)

    check tracker.count(peerA) == 0
    check tracker.count(peerB) == 1

  test "clearPeer on unknown peer is a no-op":
    tracker.clearPeer(peerA)
    check tracker.count(peerA) == 0

suite "PeerInFlightTracker - sweep":
  var tracker: PeerInFlightTracker
  var peerA, peerB: PeerId

  setup:
    tracker = PeerInFlightTracker.new()
    peerA = PeerId.example
    peerB = PeerId.example

  test "sweep compacts all peers":
    let
      doneA = newFuture[void]()
      liveA = newFuture[void]()
      doneB = newFuture[void]()
    tracker.track(peerA, doneA)
    tracker.track(peerA, liveA)
    tracker.track(peerB, doneB)
    doneA.complete()
    doneB.complete()

    waitFor tracker.sweep()

    check tracker.count(peerA) == 1
    check peerB notin tracker.peerInFlight
