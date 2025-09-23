{.push raises: [].}

## This file contains the upload request.
## A session is created for each upload allowing to resume,
## pause (using chunks) and cancels uploads.
##
## There are two ways to upload a file:
## 1. Via chunks: the filepath parameter is the data filename. Steps are:
##  - INIT: creates a new upload session and returns its ID.
##  - CHUNK: sends a chunk of data to the upload session.
##  - FINALIZE: finalizes the upload and returns the CID of the uploaded file.
##  - CANCEL: cancels the upload session.
##
## 2. Directly from a file path: the filepath has to be absolute.
##  - INIT: creates a new upload session and returns its ID
##  - FILE: starts the upload and returns the CID of the uploaded file
##  when the upload is done.
##  - CANCEL: cancels the upload session.

import std/[options, os, mimetypes, streams]
import chronos
import chronicles
import questionable
import questionable/results
import faststreams/inputs
import libp2p/stream/[bufferstream, lpstream]
import ../../alloc
import ../../../codex/units
import ../../../codex/codextypes

from ../../../codex/codex import CodexServer, node
from ../../../codex/node import store
from libp2p import Cid

type NodeUploadMsgType* = enum
  INIT
  CHUNK
  FINALIZE
  CANCEL
  FILE

type OnProgressHandler =
  proc(bytes: int): Future[void] {.gcsafe, async: (raises: [CancelledError]).}

type NodeUploadRequest* = object
  operation: NodeUploadMsgType
  sessionId: cstring
  filepath: cstring
  chunk: seq[byte]
  chunkSize: csize_t
  onProgress: OnProgressHandler

type
  UploadSessionId* = string
  UploadSessionCount* = int
  UploadSession* = object
    stream: BufferStream
    fut: Future[?!Cid]
    filepath: string

var uploadSessions {.threadvar.}: Table[UploadSessionId, UploadSession]
var nexUploadSessionCount {.threadvar.}: UploadSessionCount

proc createShared*(
    T: type NodeUploadRequest,
    op: NodeUploadMsgType,
    sessionId: cstring = "",
    filepath: cstring = "",
    chunk: seq[byte] = @[],
    onProgress: OnProgressHandler = nil,
    chunkSize: csize_t = 0,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].sessionId = sessionId.alloc()
  ret[].filepath = filepath.alloc()
  ret[].chunk = chunk
  ret[].chunkSize = chunkSize
  ret[].onProgress = onProgress
  return ret

proc destroyShared(self: ptr NodeUploadRequest) =
  deallocShared(self[].filepath)
  deallocShared(self[].sessionId)
  deallocShared(self)

proc init(
    codex: ptr CodexServer,
    filepath: cstring = "",
    chunkSize: csize_t = 0,
    onProgress: OnProgressHandler,
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Init a new session upload and return its ID.
  ## The session contains the future corresponding to the
  ## `node.store` call.
  ## The filepath can be:
  ##  - the filename when uploading via chunks
  ##  - the absolute path to a file when uploading directly.
  ## The mimetype is deduced from the filename extension.
  ##
  ## The chunkSize matches by default the block size used to store the file.
  ##
  ## An onProgress handler can be provided to get upload progress.
  ## The handler is called with the size of the block stored in the node
  ## when a new block is put in the node.
  ## After the `node.store` future is completed, whether successfully or not,
  ## the onProgress handler is called with -1 to signal the end of the upload.
  ## This allows to clean up the cGo states.

  var filenameOpt, mimetypeOpt = string.none

  if isAbsolute($filepath):
    if not fileExists($filepath):
      return err("File does not exist")

  if filepath != "":
    let (_, name, ext) = splitFile($filepath)

    filenameOpt = (name & ext).some

    if ext != "":
      let extNoDot =
        if ext.len > 0:
          ext[1 ..^ 1]
        else:
          ""
      let mime = newMimetypes()
      let mimetypeStr = mime.getMimetype(extNoDot, "")

      mimetypeOpt = if mimetypeStr == "": string.none else: mimetypeStr.some

  let sessionId = $nexUploadSessionCount
  nexUploadSessionCount.inc()

  let stream = BufferStream.new()
  let lpStream = LPStream(stream)
  let node = codex[].node

  let onBlockStore = proc(
      chunk: seq[byte]
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    discard onProgress(chunk.len)

  let blockSize =
    if chunkSize.NBytes > 0.NBytes: chunkSize.NBytes else: DefaultBlockSize
  let fut = node.store(lpStream, filenameOpt, mimetypeOpt, blockSize, onBlockStore)

  proc cb(_: pointer) {.raises: [].} =
    # Signal end of upload
    discard onProgress(-1)

  fut.addCallback(cb)

  uploadSessions[sessionId] =
    UploadSession(stream: stream, fut: fut, filepath: $filepath)

  return ok(sessionId)

proc chunk(
    codex: ptr CodexServer, sessionId: cstring, chunk: seq[byte]
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Upload a chunk of data to the session identified by sessionId.
  ## The chunk is pushed to the BufferStream of the session.

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
  ## Finalize the upload session identified by sessionId.
  ## This closes the BufferStream and waits for the `node.store` future
  ## to complete. It returns the CID of the uploaded file.
  ##
  ## In the finally block, the cleanup section removes the session
  ## from the table and cancels the future if it is not complete (in
  ## case of errors).

  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  var session: UploadSession
  try:
    session = uploadSessions[$sessionId]
    await session.stream.pushEof()

    let res = await session.fut
    if res.isErr:
      return err("Upload failed: " & res.error().msg)

    return ok($res.get())
  except KeyError as e:
    return err("Invalid session ID")
  except LPStreamError as e:
    return err("Stream error: " & $e.msg)
  except CancelledError as e:
    return err("Operation cancelled")
  except CatchableError as e:
    return err("Upload failed: " & $e.msg)
  finally:
    if uploadSessions.contains($sessionId):
      uploadSessions.del($sessionId)

    if session.fut != nil and not session.fut.finished():
      session.fut.cancelSoon()

proc cancel(
    codex: ptr CodexServer, sessionId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Cancel the upload session identified by sessionId.
  ## This cancels the `node.store` future and removes the session
  ## from the table.

  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  try:
    let session = uploadSessions[$sessionId]
    session.fut.cancelSoon()
  except KeyError as e:
    return err("Invalid session ID")

  uploadSessions.del($sessionId)

  return ok("")

proc streamFile(
    filepath: string, stream: BufferStream
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Streams a file from the given filepath using faststream.
  ## fsMultiSync cannot be used with chronos because of this warning:
  ## Warning: chronos backend uses nested calls to `waitFor` which
  ## is not supported by chronos - it is not recommended to use it until
  ## this has been resolved.
  ##
  ## Ideally when it is solved, we should use fsMultiSync or find a way to use async
  ## file I/O with chronos, see  https://github.com/status-im/nim-chronos/issues/501.

  try:
    let inputStreamHandle = filePath.fileInput()
    let inputStream = inputStreamHandle.implicitDeref

    while inputStream.readable:
      let byt = inputStream.read
      await stream.pushData(@[byt])
    return ok()
  except IOError, OSError, LPStreamError:
    let e = getCurrentException()
    return err("Stream error: " & $e.msg)

proc file(
    codex: ptr CodexServer, sessionId: cstring
): Future[Result[string, string]] {.raises: [], async: (raises: []).} =
  ## Starts the file upload for the session identified by sessionId.
  ## Will call finalize when done and return the CID of the uploaded file.
  ## In the finally block, the cleanup section removes the session
  ## from the table and cancels the future if it is not complete (in
  ## case of errors).
  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  var session: UploadSession

  try:
    session = uploadSessions[$sessionId]
    let res = await streamFile(session.filepath, session.stream)
    if res.isErr:
      return err("Failed to stream file: " & res.error)

    return await codex.finalize(sessionId)
  except KeyError as e:
    return err("Invalid session ID")
  except LPStreamError, IOError:
    let e = getCurrentException()
    return err("Stream error: " & $e.msg)
  except CancelledError as e:
    return err("Operation cancelled")
  except CatchableError as e:
    return err("Upload failed: " & $e.msg)
  finally:
    if uploadSessions.contains($sessionId):
      uploadSessions.del($sessionId)

    if session.fut != nil and not session.fut.finished():
      session.fut.cancelSoon()

proc process*(
    self: ptr NodeUploadRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeUploadMsgType.INIT:
    let res = (await init(codex, self.filepath, self.chunkSize, self.onProgress))
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
  of NodeUploadMsgType.FILE:
    let res = (await file(codex, self.sessionId))
    if res.isErr:
      error "FILE failed", error = res.error
      return err($res.error)
    return res

  return ok("")
