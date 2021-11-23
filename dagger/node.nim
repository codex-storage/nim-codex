## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronicles
import pkg/chronos
import pkg/libp2p

import ./conf

type
  DaggerNodeRef* = ref object
    switch*: Switch
    switchFuts: seq[Future[void]]

proc start*(node: DaggerNodeRef) {.async.} =
  node.switchFuts = await node.switch.start()

proc stop*(node: DaggerNodeRef) {.async.} =
  await node.switch.stop()
  await allFuturesThrowing(
    allFinished(node.switchFuts))

proc new*(
  T: type DaggerNodeRef,
  switch: Switch,
  conf: DaggerConf): T =
  T(switch: switch)
