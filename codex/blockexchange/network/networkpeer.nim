## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises
push: {.upraises: [].}

import pkg/chronos
import ../../asyncyeah
import pkg/chronicles
import pkg/libp2p

import ../protobuf/blockexc
import ../../errors

logScope:
  topics = "codex blockexcnetworkpeer"

const
  MaxMessageSize = 100 * 1 shl 20 # manifest files can be big

type
  ConnProvider* = proc(): Future[Connection] {.gcsafe, closure.}

  RPCHandler* = proc(peer: NetworkPeer, msg: Message): Future[void] {.gcsafe.}

  NetworkPeer* = ref object of RootObj
    id*: PeerId
    handler*: RPCHandler
    sendConn: Connection
    getConn: ConnProvider

proc connected*(b: NetworkPeer): bool =
  not(isNil(b.sendConn)) and
  not(b.sendConn.closed or b.sendConn.atEof)

proc readLoop*(b: NetworkPeer, conn: Connection) {.asyncyeah.} =
  if isNil(conn):
    return

  try:
    while not conn.atEof or not conn.closed:
      let
        data = await conn.readLp(MaxMessageSize)
        msg = Message.protobufDecode(data).mapFailure().tryGet()
      trace "Got message for peer", peer = b.id
      await b.handler(b, msg)
  except CatchableError as exc:
    trace "Exception in blockexc read loop", exc = exc.msg
  finally:
    await conn.close()

proc connect*(b: NetworkPeer): Future[Connection] {.asyncyeah.} =
  if b.connected:
    return b.sendConn

  b.sendConn = await b.getConn()
  asyncSpawn b.readLoop(b.sendConn)
  return b.sendConn

proc send*(b: NetworkPeer, msg: Message) {.asyncyeah.} =
  let conn = await b.connect()

  if isNil(conn):
    trace "Unable to get send connection for peer message not sent", peer = b.id
    return

  trace "Sending message to remote", peer = b.id
  await conn.writeLp(protobufEncode(msg))

proc broadcast*(b: NetworkPeer, msg: Message) =
  proc sendAwaiter() {.asyncyeah.} =
    try:
      await b.send(msg)
    except CatchableError as exc:
      trace "Exception broadcasting message to peer", peer = b.id, exc = exc.msg

  asyncSpawn sendAwaiter()

func new*(
  T: type NetworkPeer,
  peer: PeerId,
  connProvider: ConnProvider,
  rpcHandler: RPCHandler
): NetworkPeer =

  doAssert(not isNil(connProvider),
    "should supply connection provider")

  NetworkPeer(
    id: peer,
    getConn: connProvider,
    handler: rpcHandler)
