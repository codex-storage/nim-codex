## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/stew/endians2
import std/tables

import ../protocol/message
import ../protocol/constants
import ../../errors
import ../../logutils
import ../../utils/trackedfutures
import ../../blocktype
import ../types
import ../protocol/wantblocks

export wantblocks

logScope:
  topics = "storage blockexcnetworkpeer"

const DefaultYieldInterval = 50.millis

type
  ConnProvider* = proc(): Future[Connection] {.async: (raises: [CancelledError]).}

  RPCHandler* = proc(peer: NetworkPeer, msg: Message) {.async: (raises: []).}

  WantBlocksRequestHandler* = proc(
    peer: PeerId, req: WantBlocksRequest
  ): Future[seq[BlockDelivery]] {.async: (raises: [CancelledError]).}

  WantBlocksResponseFuture* = Future[WantBlocksResult[WantBlocksResponse]]

  NetworkPeer* = ref object of RootObj
    id*: PeerId
    handler*: RPCHandler
    wantBlocksHandler*: WantBlocksRequestHandler
    sendConn: Connection
    getConn: ConnProvider
    yieldInterval*: Duration = DefaultYieldInterval
    trackedFutures: TrackedFutures
    pendingWantBlocksRequests*: Table[uint64, WantBlocksResponseFuture]
    nextRequestId*: uint64

proc connected*(self: NetworkPeer): bool =
  not (isNil(self.sendConn)) and not (self.sendConn.closed or self.sendConn.atEof)

proc readLoop*(self: NetworkPeer, conn: Connection) {.async: (raises: []).} =
  if isNil(conn):
    trace "No connection to read from", peer = self.id
    return

  trace "Attaching read loop", peer = self.id, connId = conn.oid
  try:
    var nextYield = Moment.now() + self.yieldInterval
    while not conn.atEof and not conn.closed:
      if Moment.now() > nextYield:
        nextYield = Moment.now() + self.yieldInterval
        await sleepAsync(10.millis)

      var lenBuf: array[4, byte]
      await conn.readExactly(addr lenBuf[0], 4)
      let frameLen = uint32.fromBytes(lenBuf, littleEndian).int

      if frameLen < 1:
        warn "Frame too short", peer = self.id, frameLen = frameLen
        return

      var typeByte: array[1, byte]
      await conn.readExactly(addr typeByte[0], 1)

      if typeByte[0] > ord(high(MessageType)):
        warn "Invalid message type byte", peer = self.id, typeByte = typeByte[0]
        return

      let
        msgType = MessageType(typeByte[0])
        dataLen = frameLen - 1

      case msgType
      of mtProtobuf:
        if dataLen > MaxMessageSize.int:
          warn "Protobuf message too large", peer = self.id, size = dataLen
          return

        var data = newSeq[byte](dataLen)
        if dataLen > 0:
          await conn.readExactly(addr data[0], dataLen)

        let msg = Message.protobufDecode(data).mapFailure().tryGet()
        await self.handler(self, msg)
      of mtWantBlocksRequest:
        let reqResult = await readWantBlocksRequest(conn, dataLen)
        if reqResult.isErr:
          warn "Failed to read WantBlocks request",
            peer = self.id, error = reqResult.error.msg
          return

        let
          req = reqResult.get
          blocks = await self.wantBlocksHandler(self.id, req)
        await writeWantBlocksResponse(conn, req.requestId, req.cid, blocks)
      of mtWantBlocksResponse:
        let respResult = await readWantBlocksResponse(conn, dataLen)
        if respResult.isErr:
          warn "Failed to read WantBlocks response",
            peer = self.id, error = respResult.error.msg
          return

        let response = respResult.get
        self.pendingWantBlocksRequests.withValue(response.requestId, fut):
          if not fut[].finished:
            fut[].complete(WantBlocksResult[WantBlocksResponse].ok(response))
          self.pendingWantBlocksRequests.del(response.requestId)
        do:
          warn "Received WantBlocks response for unknown request ID",
            peer = self.id, requestId = response.requestId
  except CancelledError:
    trace "Read loop cancelled"
  except CatchableError as err:
    warn "Exception in blockexc read loop", msg = err.msg
  finally:
    warn "Detaching read loop", peer = self.id, connId = conn.oid
    for requestId, fut in self.pendingWantBlocksRequests:
      if not fut.finished:
        fut.complete(
          WantBlocksResult[WantBlocksResponse].err(
            wantBlocksError(ConnectionClosed, "Read loop exited")
          )
        )
    self.pendingWantBlocksRequests.clear()
    if self.sendConn == conn:
      self.sendConn = nil
    await conn.close()

proc connect*(
    self: NetworkPeer
): Future[Connection] {.async: (raises: [CancelledError]).} =
  if self.connected:
    trace "Already connected", peer = self.id, connId = self.sendConn.oid
    return self.sendConn

  self.sendConn = await self.getConn()
  self.trackedFutures.track(self.readLoop(self.sendConn))
  return self.sendConn

proc send*(
    self: NetworkPeer, msg: Message
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let conn = await self.connect()

  if isNil(conn):
    warn "Unable to get send connection for peer message not sent", peer = self.id
    return

  try:
    let msgData = protobufEncode(msg)

    let
      frameLen = 1 + msgData.len
      totalSize = 4 + frameLen
    var buf = newSeq[byte](totalSize)

    let lenBytes = uint32(frameLen).toBytes(littleEndian)
    copyMem(addr buf[0], unsafeAddr lenBytes[0], 4)

    buf[4] = mtProtobuf.byte

    if msgData.len > 0:
      copyMem(addr buf[5], unsafeAddr msgData[0], msgData.len)

    await conn.write(buf)
  except CatchableError as err:
    if self.sendConn == conn:
      self.sendConn = nil
    raise newException(LPStreamError, "Failed to send message: " & err.msg)

proc sendWantBlocksRequest*(
    self: NetworkPeer, blockRange: BlockRange
): Future[WantBlocksResult[WantBlocksResponse]] {.async: (raises: [CancelledError]).} =
  let requestId = self.nextRequestId
  self.nextRequestId += 1

  let responseFuture = WantBlocksResponseFuture.init("wantBlocksRequest")
  self.pendingWantBlocksRequests[requestId] = responseFuture

  try:
    let conn = await self.connect()
    if isNil(conn):
      self.pendingWantBlocksRequests.del(requestId)
      return err(wantBlocksError(NoConnection, "No connection available"))

    let req = WantBlocksRequest(
      requestId: requestId, cid: blockRange.cid, ranges: blockRange.ranges
    )
    await writeWantBlocksRequest(conn, req)
    return await responseFuture
  except CancelledError as exc:
    self.pendingWantBlocksRequests.del(requestId)
    raise exc
  except CatchableError as err:
    self.pendingWantBlocksRequests.del(requestId)
    return err(wantBlocksError(RequestFailed, "WantBlocks request failed: " & err.msg))

func new*(
    T: type NetworkPeer,
    peer: PeerId,
    connProvider: ConnProvider,
    rpcHandler: RPCHandler,
    wantBlocksHandler: WantBlocksRequestHandler,
): NetworkPeer =
  doAssert(not isNil(connProvider), "should supply connection provider")

  NetworkPeer(
    id: peer,
    getConn: connProvider,
    handler: rpcHandler,
    wantBlocksHandler: wantBlocksHandler,
    trackedFutures: TrackedFutures(),
  )
