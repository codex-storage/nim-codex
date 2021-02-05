## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/chronicles
import pkg/protobuf_serialization
import pkg/libp2p/stream/connection
import pkg/libp2p/peerid

import ./protobuf/bitswap

const MaxMessageSize = 8 * 1024 * 1024

type
  RPCHandler* = proc(peer: NetworkPeer, msg: Message): Future[void] {.gcsafe.}
  GetConn* = proc(): Future[Connection]

  NetworkPeer* = ref object of RootObj
    id*: PeerId
    handler*: RPCHandler
    sendConn: Connection
    getConn: GetConn

proc connected*(b: NetworkPeer): bool =
  not b.sendConn.isNil and not
    (b.sendConn.closed or b.sendConn.atEof)

proc readLoop*(b: NetworkPeer, conn: Connection) {.async.} =
  if isNil(conn):
    return

  try:
    while not conn.atEof:
      let data = await conn.readLp(MaxMessageSize)
      let msg: Message = Protobuf.decode(data, Message)
      await b.handler(b, msg)
  except CatchableError as exc:
    trace "Exception in bitswap read loop", exc = exc.msg
  finally:
    await conn.close()

proc connect*(b: NetworkPeer): Future[Connection] {.async.} =
  if b.connected:
    return

  b.sendConn = await b.getConn()
  asyncCheck b.readLoop(b.sendConn)
  return b.sendConn

proc send*(b: NetworkPeer, msg: Message) {.async.} =
  await (await b.connect()).writeLp(Protobuf.encode(msg))

proc new*(
  T: type NetworkPeer,
  peer: PeerId,
  connProvider: GetConn,
  rpcHandler: RPCHandler): T =

  NetworkPeer(
    id: peer,
    getConn: connProvider,
    handler: rpcHandler)
