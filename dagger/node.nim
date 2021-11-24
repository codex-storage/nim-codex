## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options

import pkg/chronicles
import pkg/chronos
import pkg/libp2p

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope

import ./conf

type
  DaggerNodeRef* = ref object
    switch*: Switch
    config*: DaggerConf

proc start*(node: DaggerNodeRef) {.async.} =
  discard await node.switch.start()
  echo "NODES ", $node.switch.peerInfo.peerId

proc stop*(node: DaggerNodeRef) {.async.} =
  await node.switch.stop()

proc findPeer*(
  node: DaggerNodeRef,
  peerId: PeerID): Future[Result[PeerRecord, string]] {.async.} =
  discard

proc connect*(
  node: DaggerNodeRef,
  peerId: PeerID,
  addrs: seq[MultiAddress]): Future[void] =
  node.switch.connect(peerId, addrs)

proc new*(
  T: type DaggerNodeRef,
  switch: Switch,
  config: DaggerConf): T =
  T(switch: switch, config: config)
