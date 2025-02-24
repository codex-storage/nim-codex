## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises
push:
  {.upraises: [].}

import pkg/chronos
import pkg/libp2p

import ../protobuf/blockexc
import ../protobuf/message
import ../../errors
import ../../logutils

logScope:
  topics = "codex blockexcnetworkpeer"

const DefaultYieldInterval = 50.millis

type
  ConnProvider* = proc(): Future[Connection] {.gcsafe, closure.}

  RPCHandler* = proc(
    peer: NetworkPeer, msg: Message
  ): Future[void].Raising(CatchableError) {.gcsafe.}

  NetworkPeer* = ref object of RootObj
    id*: PeerId
    handler*: RPCHandler
    sendConn: Connection
    getConn: ConnProvider
    yieldInterval*: Duration = DefaultYieldInterval

proc connected*(b: NetworkPeer): bool =
  not (isNil(b.sendConn)) and not (b.sendConn.closed or b.sendConn.atEof)

proc readLoop*(b: NetworkPeer, conn: Connection) {.async.} =
  if isNil(conn):
    trace "No connection to read from", peer = b.id
    return

  trace "Attaching read loop", peer = b.id, connId = conn.oid
  try:
    var nextYield = Moment.now() + b.yieldInterval
    while not conn.atEof or not conn.closed:
      if Moment.now() > nextYield:
        nextYield = Moment.now() + b.yieldInterval
        trace "Yielding in read loop",
          peer = b.id, nextYield = nextYield, interval = b.yieldInterval
        await sleepAsync(10.millis)

      let
        data = await conn.readLp(MaxMessageSize.int)
        msg = Message.protobufDecode(data).mapFailure().tryGet()
      trace "Received message", peer = b.id, connId = conn.oid
      await b.handler(b, msg)
  except CancelledError:
    trace "Read loop cancelled"
  except CatchableError as err:
    warn "Exception in blockexc read loop", msg = err.msg
  finally:
    trace "Detaching read loop", peer = b.id, connId = conn.oid
    await conn.close()

proc connect*(b: NetworkPeer): Future[Connection] {.async.} =
  if b.connected:
    trace "Already connected", peer = b.id, connId = b.sendConn.oid
    return b.sendConn

  b.sendConn = await b.getConn()
  asyncSpawn b.readLoop(b.sendConn)
  return b.sendConn

proc send*(b: NetworkPeer, msg: Message) {.async.} =
  let conn = await b.connect()

  if isNil(conn):
    warn "Unable to get send connection for peer message not sent", peer = b.id
    return

  trace "Sending message", peer = b.id, connId = conn.oid
  await conn.writeLp(protobufEncode(msg))

func new*(
    T: type NetworkPeer,
    peer: PeerId,
    connProvider: ConnProvider,
    rpcHandler: RPCHandler,
): NetworkPeer =
  doAssert(not isNil(connProvider), "should supply connection provider")

  NetworkPeer(id: peer, getConn: connProvider, handler: rpcHandler)
