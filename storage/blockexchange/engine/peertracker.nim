## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[tables, sequtils]

import pkg/chronos
import pkg/libp2p/peerid

const SweepRuntimeQuota* = 5.milliseconds

type PeerInFlightTracker* = ref object
  peerInFlight*: Table[PeerId, seq[Future[void]]]
    # track in-flight requests per peer for BDP - used as self-cleaning counter

proc new*(T: type PeerInFlightTracker): PeerInFlightTracker =
  PeerInFlightTracker(peerInFlight: initTable[PeerId, seq[Future[void]]]())

proc count*(self: PeerInFlightTracker, peerId: PeerId): int =
  self.peerInFlight.withValue(peerId, lst):
    var live: seq[Future[void]]
    for fut in lst[]:
      if not fut.finished:
        live.add(fut)
    if live.len < lst[].len:
      if live.len == 0:
        self.peerInFlight.del(peerId)
      else:
        self.peerInFlight[peerId] = live
    return live.len
  return 0

proc track*(self: PeerInFlightTracker, peerId: PeerId, fut: Future[void]) =
  self.peerInFlight.mgetOrPut(peerId, @[]).add(fut)

proc clearPeer*(self: PeerInFlightTracker, peerId: PeerId) =
  self.peerInFlight.del(peerId)

proc sweep*(self: PeerInFlightTracker) {.async: (raises: [CancelledError]).} =
  var lastIdle = Moment.now()
  for peerId in self.peerInFlight.keys.toSeq:
    discard self.count(peerId)
    if (Moment.now() - lastIdle) >= SweepRuntimeQuota:
      await sleepAsync(ZeroDuration)
      lastIdle = Moment.now()
