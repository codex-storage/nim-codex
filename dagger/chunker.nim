## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# TODO: This is super inneficient and needs a rewrite, but it'll do for now

{.push raises: [Defect].}

import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/libp2p
import pkg/chronicles

import ./rng
import ./blocktype
import ./utils/asyncfutures

export blocktype

const
  DefaultChunkSize*: int64 = 1024 * 256

type
  # default reader type
  ChunkBuffer* = ptr UncheckedArray[byte]
  Reader* =
    proc(data: ChunkBuffer, len: int): Future[int] {.gcsafe, raises: [Defect].}

  ChunkerType* {.pure.} = enum
    FixedChunker
    RabinChunker

  Chunker* = ref object of RootObj
    reader*: Reader
    case kind*: ChunkerType:
    of FixedChunker:
      chunkSize*: Natural
      pad*: bool # pad last block if less than size
    of RabinChunker:
      discard

  FileChunker* = Chunker
  LPStreamChunker* = Chunker
  RandomChunker* = Chunker

proc getBytes*(c: Chunker): Future[seq[byte]] {.async.} =
  ## returns a chunk of bytes from
  ## the instantiated chunker
  ##

  var buff = newSeq[byte](c.chunkSize)
  let read = await c.reader(cast[ChunkBuffer](addr buff[0]), buff.len)

  if read <= 0:
    return @[]

  if not c.pad and buff.len != read:
    buff.setLen(read)

  return buff

func new*(
  T: type Chunker,
  kind = ChunkerType.FixedChunker,
  reader: Reader,
  chunkSize = DefaultChunkSize,
  pad = false): T =
  var chunker = Chunker(
    kind: kind,
    reader: reader)

  if kind == ChunkerType.FixedChunker:
    chunker.pad = pad
    chunker.chunkSize = chunkSize

  return chunker

proc new*(
  T: type RandomChunker,
  rng: Rng,
  size: int64,
  kind = ChunkerType.FixedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): T =
  ## create a chunker that produces
  ## random data
  ##

  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.gcsafe, raises: [Defect].} =
    var alpha = toSeq(byte('A')..byte('z'))

    var read = 0
    while read <= data.high:
      rng.shuffle(alpha)
      for a in alpha:
        if read > data.high:
          break

        data[read] = a
        read.inc

    return read

  Chunker.new(
    kind = ChunkerType.FixedChunker,
    reader = reader,
    pad = pad,
    chunkSize = chunkSize)

proc new*(
  T: type LPStreamChunker,
  stream: LPStream,
  kind = ChunkerType.FixedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): T =
  ## create the default File chunker
  ##

  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.gcsafe, async, raises: [Defect].} =
    try:
      var res = 0
      while res <= len:
        if stream.atEof and stream.closed:
          break

        res += await stream.readOnce(data, len)

      return res
    except LPStreamEOFError as exc:
      return 0
      trace "LPStreamChunker stream Eof", exc = exc.msg
    except CatchableError as exc:
      trace "CatchableError exception", exc = exc.msg
      raise newException(Defect, exc.msg)

  Chunker.new(
    kind = ChunkerType.FixedChunker,
    reader = reader,
    pad = pad,
    chunkSize = chunkSize)

proc new*(
  T: type FileChunker,
  file: File,
  kind = ChunkerType.FixedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): T =
  ## create the default File chunker
  ##

  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.gcsafe, async, raises: [Defect].} =
    try:
      return file.readBuffer(addr data[0], len)
    except IOError as exc:
      # TODO: revisit error handling - should this be fatal?
      raise newException(Defect, exc.msg)

  Chunker.new(
    kind = ChunkerType.FixedChunker,
    reader = reader,
    pad = pad,
    chunkSize = chunkSize)

proc toStream*(
  chunker: Chunker): AsyncFutureStream[seq[byte]] =
  let
    stream = AsyncPushable[seq[byte]].new()

  proc pusher() {.async, nimcall, raises: [Defect].} =
    try:
      while true:
        let buf = await chunker.getBytes()
        if buf.len <= 0:
          break

        await stream.push(buf)
    except AsyncFutureStreamError as exc:
      trace "Exception pushing to futures stream", exc = exc.msg
    except CatchableError as exc:
      trace "Unknown exception, raising defect", exc = exc.msg
      raiseAssert exc.msg
    finally:
      stream.finish()

  asyncSpawn pusher()
  return stream
