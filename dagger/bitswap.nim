## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options
import pkg/chronos
import pkg/libp2p/cid
import ./ipfsobject
import ./repo
import ./p2p/switch
import ./bitswap/protocol
import ./bitswap/exchange

export options
export Cid
export Switch

type
  Bitswap* = ref object
    repo: Repo
    switch: Switch
    exchanges: seq[Exchange] # TODO: never cleaned

proc startExchange(bitswap: Bitswap, stream: BitswapStream) =
  let exchange = Exchange.start(bitswap.repo, stream)
  bitswap.exchanges.add(exchange)

proc start*(_: type Bitswap, switch: Switch, repo = Repo()): Bitswap =
  let bitswap = Bitswap(repo: repo, switch: switch)
  let protocol = BitswapProtocol.new()
  proc acceptLoop {.async.} =
    while true:
      let stream = await protocol.accept()
      bitswap.startExchange(stream)
  asyncSpawn acceptLoop()
  switch.mount(protocol)
  bitswap

proc connect*(bitswap: Bitswap, peer: PeerInfo) {.async.} =
  let stream = await bitswap.switch.dial(peer, BitswapProtocol)
  bitswap.startExchange(stream)

proc store*(bitswap: Bitswap, obj: IpfsObject) =
  bitswap.repo.store(obj)

proc retrieve*(bitswap: Bitswap,
               cid: Cid,
               timeout = 30.seconds): Future[Option[IpfsObject]] {.async.} =
  result = bitswap.repo.retrieve(cid)
  if result.isNone:
    for exchange in bitswap.exchanges:
      await exchange.want(cid)
    await bitswap.repo.wait(cid, timeout)
    result = bitswap.repo.retrieve(cid)
