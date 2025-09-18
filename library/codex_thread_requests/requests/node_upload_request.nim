## This file contains the lifecycle request type that will be handled.

import std/[options, os, mimetypes]
import chronos
import chronicles
import libp2p
import ../../alloc
import ../../../codex/streams
import ../../../codex/node

from ../../../codex/codex import CodexServer, node

type NodeUploadMsgType* = enum
  INIT
  CHUNK
  FINALIZE
  CANCEL

type NodeUploadRequest* = object
  operation: NodeUploadMsgType
  mimetype: cstring
  filename: cstring
  sessionId: cstring
  chunk: seq[byte]

type
  UploadSessionId* = string
  UploadSessionCount* = int
  UploadSession* = object
    stream: BufferStream
    fut: Future[?!Cid]

var uploadSessions {.threadvar.}: Table[UploadSessionId, UploadSession]
var nexUploadSessionCount {.threadvar.}: UploadSessionCount

proc createShared*(
    T: type NodeUploadRequest,
    op: NodeUploadMsgType,
    mimetype: cstring = "",
    filename: cstring = "",
    sessionId: cstring = "",
    chunk: seq[byte] = @[],
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].mimetype = mimetype.alloc()
  ret[].filename = filename.alloc()
  ret[].sessionId = sessionId.alloc()
  ret[].chunk = chunk
  return ret

proc destroyShared(self: ptr NodeUploadRequest) =
  deallocShared(self[].mimetype)
  deallocShared(self[].filename)
  deallocShared(self[].sessionId)
  deallocShared(self)

## Init upload create a new upload session and returns its ID.
## The session can be used to send chunks of data
## and to pause and resume the upload.
proc init(
    codex: ptr CodexServer, mimetype: cstring, filename: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  if $filename != "" and not isValidFilename($filename):
    return err("Invalid filename")

  if $mimetype != "":
    let m = newMimetypes()
    if m.getExt($mimetype, "") == "":
      return err("Invalid MIME type")

  let sessionId = $nexUploadSessionCount
  nexUploadSessionCount.inc()

  let stream = BufferStream.new()
  let lpStream = LPStream(stream)
  let node = codex[].node
  let fut = node.store(lpStream, ($filename).some, ($mimetype).some)
  uploadSessions[sessionId] = UploadSession(stream: stream, fut: fut)

  return ok(sessionId)

proc chunk(
    codex: ptr CodexServer, sessionId: cstring, chunk: seq[byte]
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  try:
    let session = uploadSessions[$sessionId]
    await session.stream.pushData(chunk)
  except KeyError as e:
    return err("Invalid session ID")
  except LPError as e:
    return err("Stream error: " & $e.msg)
  except CancelledError as e:
    return err("Operation cancelled")

  return ok("")

proc finalize(
    codex: ptr CodexServer, sessionId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  var session: UploadSession
  try:
    session = uploadSessions[$sessionId]
    await session.stream.pushEof()
  except KeyError as e:
    return err("Invalid session ID")
  except LPStreamError as e:
    return err("Stream error: " & $e.msg)
  except CancelledError as e:
    return err("Operation cancelled")

  try:
    let res = await session.fut
    if res.isErr:
      return err("Upload failed: " & res.error().msg)

    return ok($res.get())
  except CatchableError as e:
    return err("Upload failed: " & $e.msg)
  finally:
    uploadSessions.del($sessionId)

proc cancel(
    codex: ptr CodexServer, sessionId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  try:
    let session = uploadSessions[$sessionId]
    session.fut.cancel()
  except KeyError as e:
    return err("Invalid session ID")

  uploadSessions.del($sessionId)

  return ok("")

proc process*(
    self: ptr NodeUploadRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeUploadMsgType.INIT:
    let res = (await init(codex, self.mimetype, self.filename))
    if res.isErr:
      error "INIT failed", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.CHUNK:
    let res = (await chunk(codex, self.sessionId, self.chunk))
    if res.isErr:
      error "CHUNK failed", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.FINALIZE:
    let res = (await finalize(codex, self.sessionId))
    if res.isErr:
      error "FINALIZE failed", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.CANCEL:
    let res = (await cancel(codex, self.sessionId))
    if res.isErr:
      error "CANCEL failed", error = res.error
      return err($res.error)
    return res

  return ok("")
