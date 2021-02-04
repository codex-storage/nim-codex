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
  GetConn* = proc(): Future[Connection]

  BitswapPeer* = ref object of RootObj
    id*: PeerId
    sendConn: Connection
    getConn: GetConn

proc connected*(b: BitswapPeer): bool =
  not b.sendConn.isNil and not
    (b.sendConn.closed or b.sendConn.atEof)

proc handleWantList(b: BitswapPeer, list: WantList) =
  discard

proc handleBlocks(b: BitswapPeer, blocks: seq[auto]) =
  discard

proc handlePayload(b: BitswapPeer, payload: seq[Block]) =
  discard

proc handleBlockPresense(b: BitswapPeer, presense: seq[BlockPresence]) =
  discard

proc readLoop*(b: BitswapPeer, conn: Connection) {.async.} =
  if isNil(conn):
    return

  try:
    while not conn.atEof:
      let data = await conn.readLp(MaxMessageSize)
      let msg: Message = Protobuf.decode(data, Message)

      if msg.wantlist.entries.len > 0:
        b.handleWantList(msg.wantlist)

      if msg.blocks.len > 0:
        b.handleBlocks(msg.blocks)

      if msg.payload.len > 0:
        b.handlePayload(msg.payload)

      if msg.blockPresences.len > 0:
        b.handleBlockPresense(msg.blockPresences)

  except CatchableError as exc:
    trace "Exception in bitswap read loop", exc = exc.msg
  finally:
    await conn.close()

proc send*(b: BitswapPeer, msg: Message) {.async.} =
  discard

proc connect*(b: BitswapPeer) {.async.} =
  if b.connected:
    return

  b.sendConn = await b.getConn()
  asyncCheck b.readLoop(b.sendConn)

proc new*(
  T: type BitswapPeer,
  peer: PeerId,
  connProvider: GetConn): T =

  BitswapPeer(
    id: peer,
    getConn: connProvider)
