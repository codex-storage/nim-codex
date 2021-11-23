## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p
import pkg/confutils

import ./node
import ./conf
import ./rng
import ./rest/api

let
  conf = DaggerConf.load()
  addrs = conf.listenAddrs.mapIt(
    MultiAddress.init(it)
  )
  bootstrap = conf.bootstrapNodes.mapIt(
    MultiAddress.init(it)
  )

let
  switch = SwitchBuilder
  .new()
  # .withPrivateKey(seckey) # TODO: add static secret key
  .withAddress(addrs)
  .withRng(Rng.instance())
  .withNoise()
  .withMplex(5.minutes, 5.minutes)
  .withMaxConnections(config.maxPeers)
  .withAgentVersion(config.agentString)
  .withTcpTransport({ServerFlags.ReuseAddr})
  .build()

let
  node = DaggerNodeRef.new(switch)
  restServer = ? RestServerRef.init(
    initTAddress("127.0.0.1" , conf.apiPort),
    node.initRestApi())

await restServer.start()
waitFor node.start()
