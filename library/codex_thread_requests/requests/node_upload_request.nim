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
## Cancel is not supported in this mode because the worker will be busy
## uploading the file so it cannot pickup another request to cancel the upload.

import std/[options, os, mimetypes]
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
from libp2p import Cid, `$`

logScope:
  topics = "codexlib codexlibupload"

type NodeUploadMsgType* = enum
  INIT
  CHUNK
  FINALIZE
  CANCEL
  FILE

type OnProgressHandler = proc(bytes: int): void {.gcsafe, raises: [].}

type NodeUploadRequest* = object
  operation: NodeUploadMsgType
  sessionId: cstring
  filepath: cstring
  chunk: seq[byte]
  chunkSize: csize_t

type
  UploadSessionId* = string
  UploadSessionCount* = int
  UploadSession* = object
    stream: BufferStream
    fut: Future[?!Cid]
    filepath: string
    chunkSize: int
    onProgress: OnProgressHandler

var uploadSessions {.threadvar.}: Table[UploadSessionId, UploadSession]
var nexUploadSessionCount {.threadvar.}: UploadSessionCount

proc createShared*(
    T: type NodeUploadRequest,
    op: NodeUploadMsgType,
    sessionId: cstring = "",
    filepath: cstring = "",
    chunk: seq[byte] = @[],
    chunkSize: csize_t = 0,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].sessionId = sessionId.alloc()
  ret[].filepath = filepath.alloc()
  ret[].chunk = chunk
  ret[].chunkSize = chunkSize

  return ret

proc destroyShared(self: ptr NodeUploadRequest) =
  deallocShared(self[].filepath)
  deallocShared(self[].sessionId)
  deallocShared(self)

proc init(
    codex: ptr CodexServer, filepath: cstring = "", chunkSize: csize_t = 0
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
  ## A callback `onBlockStore` is provided to `node.store` to
  ## report the progress of the upload. This callback will check
  ## that an `onProgress` handler is set in the session
  ## and call it with the number of bytes stored each time a block
  ## is stored.

  var filenameOpt, mimetypeOpt = string.none

  if isAbsolute($filepath):
    if not fileExists($filepath):
      return err(
        "Failed to create an upload session, the filepath does not exist: " & $filepath
      )

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

  let onBlockStored = proc(chunk: seq[byte]): void {.gcsafe, raises: [].} =
    try:
      if uploadSessions.contains($sessionId):
        let session = uploadSessions[$sessionId]
        if session.onProgress != nil:
          session.onProgress(chunk.len)
    except KeyError:
      error "Failed to push progress update, session is not found: ",
        sessionId = $sessionId

  let blockSize =
    if chunkSize.NBytes > 0.NBytes: chunkSize.NBytes else: DefaultBlockSize
  let fut = node.store(lpStream, filenameOpt, mimetypeOpt, blockSize, onBlockStored)

  uploadSessions[sessionId] = UploadSession(
    stream: stream, fut: fut, filepath: $filepath, chunkSize: blockSize.int
  )

  return ok(sessionId)

proc chunk(
    codex: ptr CodexServer, sessionId: cstring, chunk: seq[byte]
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Upload a chunk of data to the session identified by sessionId.
  ## The chunk is pushed to the BufferStream of the session.
  ## If the chunk size is equal or greater than the session chunkSize,
  ## the `onProgress` callback is temporarily set to receive the progress
  ## from `onBlockStored` callback. This provide a way to report progress
  ## precisely when a block is stored.
  ## If the chunk size is smaller than the session chunkSize,
  ## the `onProgress` callback is not set because the LPStream will
  ## wait until enough data is received to form a block before storing it.
  ## The wrapper may then report the progress because the data is in the stream
  ## but not yet stored.

  if not uploadSessions.contains($sessionId):
    return err("Failed to upload the chunk, the session is not found: " & $sessionId)

  var fut = newFuture[void]()

  try:
    let session = uploadSessions[$sessionId]

    if chunk.len >= session.chunkSize:
      uploadSessions[$sessionId].onProgress = proc(
          bytes: int
      ): void {.gcsafe, raises: [].} =
        fut.complete()
      await session.stream.pushData(chunk)
    else:
      fut = session.stream.pushData(chunk)

    await fut

    uploadSessions[$sessionId].onProgress = nil
  except KeyError:
    return err("Failed to upload the chunk, the session is not found: " & $sessionId)
  except LPError as e:
    return err("Failed to upload the chunk, stream error: " & $e.msg)
  except CancelledError:
    return err("Failed to upload the chunk, operation cancelled.")
  except CatchableError as e:
    return err("Failed to upload the chunk: " & $e.msg)
  finally:
    if not fut.finished():
      fut.cancelSoon()

  return ok("")

proc finalize(
    codex: ptr CodexServer, sessionId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Finalize the upload session identified by sessionId.
  ## This closes the BufferStream and waits for the `node.store` future
  ## to complete. It returns the CID of the uploaded file.

  if not uploadSessions.contains($sessionId):
    return
      err("Failed to finalize the upload session, session not found: " & $sessionId)

  var session: UploadSession
  try:
    session = uploadSessions[$sessionId]
    await session.stream.pushEof()

    let res = await session.fut
    if res.isErr:
      return err("Failed to finalize the upload session: " & res.error().msg)

    return ok($res.get())
  except KeyError:
    return
      err("Failed to finalize the upload session, invalid session ID: " & $sessionId)
  except LPStreamError as e:
    return err("Failed to finalize the upload session, stream error: " & $e.msg)
  except CancelledError:
    return err("Failed to finalize the upload session, operation cancelled")
  except CatchableError as e:
    return err("Failed to finalize the upload session: " & $e.msg)
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
  ## This operation is not supported when uploading file because
  ## the worker will be busy uploading the file so it cannot pickup
  ## another request to cancel the upload.

  if not uploadSessions.contains($sessionId):
    return err("Failed to cancel the upload session, session not found: " & $sessionId)

  try:
    let session = uploadSessions[$sessionId]
    session.fut.cancelSoon()
  except KeyError:
    return err("Failed to cancel the upload session, invalid session ID: " & $sessionId)

  uploadSessions.del($sessionId)

  return ok("")

proc streamFile(
    filepath: string, stream: BufferStream, chunkSize: int
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

    var buf = newSeq[byte](chunkSize)
    while inputStream.readable:
      let read = inputStream.readIntoEx(buf)
      if read == 0:
        break
      await stream.pushData(buf[0 ..< read])
      # let byt = inputStream.read
      # await stream.pushData(@[byt])
    return ok()
  except IOError, OSError, LPStreamError:
    let e = getCurrentException()
    return err("Failed to stream the file: " & $e.msg)

proc file(
    codex: ptr CodexServer, sessionId: cstring, onProgress: OnProgressHandler
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Starts the file upload for the session identified by sessionId.
  ## Will call finalize when done and return the CID of the uploaded file.
  ##
  ## The onProgress callback is called with the number of bytes
  ## to report the progress of the upload.

  if not uploadSessions.contains($sessionId):
    return err("Failed to upload the file, invalid session ID: " & $sessionId)

  var session: UploadSession

  try:
    uploadSessions[$sessionId].onProgress = onProgress
    session = uploadSessions[$sessionId]

    let res = await streamFile(session.filepath, session.stream, session.chunkSize)
    if res.isErr:
      return err("Failed to upload the file: " & res.error)

    return await codex.finalize(sessionId)
  except KeyError:
    return err("Failed to upload the file, the session is not found: " & $sessionId)
  except LPStreamError, IOError:
    let e = getCurrentException()
    return err("Failed to upload the file: " & $e.msg)
  except CancelledError:
    return err("Failed to upload the file, the operation is cancelled.")
  except CatchableError as e:
    return err("Failed to upload the file: " & $e.msg)
  finally:
    if uploadSessions.contains($sessionId):
      uploadSessions.del($sessionId)

    if session.fut != nil and not session.fut.finished():
      session.fut.cancelSoon()

proc process*(
    self: ptr NodeUploadRequest,
    codex: ptr CodexServer,
    onUploadProgress: OnProgressHandler = nil,
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeUploadMsgType.INIT:
    let res = (await init(codex, self.filepath, self.chunkSize))
    if res.isErr:
      error "Failed to INIT.", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.CHUNK:
    let res = (await chunk(codex, self.sessionId, self.chunk))
    if res.isErr:
      error "Failed to CHUNK.", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.FINALIZE:
    let res = (await finalize(codex, self.sessionId))
    if res.isErr:
      error "Failed to FINALIZE.", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.CANCEL:
    let res = (await cancel(codex, self.sessionId))
    if res.isErr:
      error "Failed to CANCEL.", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.FILE:
    let res = (await file(codex, self.sessionId, onUploadProgress))
    if res.isErr:
      error "Failed to FILE.", error = res.error
      return err($res.error)
    return res
