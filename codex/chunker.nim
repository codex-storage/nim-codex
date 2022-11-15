## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# TODO: This is super inneficient and needs a rewrite, but it'll do for now

import pkg/upraises

push: {.upraises: [].}

import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/libp2p except shuffle

import ./blocktype

export blocktype

const
  DefaultChunkSize* = BlockSize

type
  # default reader type
  ChunkBuffer* = ptr UncheckedArray[byte]
  Reader* = proc(data: ChunkBuffer, len: int): Future[int] {.gcsafe, raises: [Defect].}

  # Reader that splits input data into fixed-size chunks
  Chunker* = ref object
    reader*: Reader             # Procedure called to actually read the data
    offset*: int                # Bytes read so far (position in the stream)
    chunkSize*: Natural         # Size of each chunk
    pad*: bool                  # Pad last chunk to chunkSize?

  FileChunker* = Chunker
  LPStreamChunker* = Chunker

proc getBytes*(c: Chunker): Future[seq[byte]] {.async.} =
  ## returns a chunk of bytes from
  ## the instantiated chunker
  ##

  var buff = newSeq[byte](c.chunkSize)
  let read = await c.reader(cast[ChunkBuffer](addr buff[0]), buff.len)

  if read <= 0:
    return @[]

  c.offset += read

  if not c.pad and buff.len > read:
    buff.setLen(read)

  return move buff

func new*(
  T: type Chunker,
  reader: Reader,
  chunkSize = DefaultChunkSize,
  pad = true): T =

  T(reader: reader,
    offset: 0,
    chunkSize: chunkSize,
    pad: pad)

proc new*(
  T: type LPStreamChunker,
  stream: LPStream,
  chunkSize = DefaultChunkSize,
  pad = true): T =
  ## create the default File chunker
  ##

  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.gcsafe, async, raises: [Defect].} =
    var res = 0
    try:
      while res < len:
        res += await stream.readOnce(addr data[res], len - res)
    except LPStreamEOFError as exc:
      trace "LPStreamChunker stream Eof", exc = exc.msg
    except CatchableError as exc:
      trace "CatchableError exception", exc = exc.msg
      raise newException(Defect, exc.msg)

    return res

  T.new(
    reader = reader,
    chunkSize = chunkSize,
    pad = pad)

proc new*(
  T: type FileChunker,
  file: File,
  chunkSize = DefaultChunkSize,
  pad = true): T =
  ## create the default File chunker
  ##

  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.gcsafe, async, raises: [Defect].} =
    var total = 0
    try:
      while total < len:
        let res = file.readBuffer(addr data[total], len - total)
        if res <= 0:
          break

        total += res
    except IOError as exc:
      trace "Exception reading file", exc = exc.msg
    except CatchableError as exc:
      trace "CatchableError exception", exc = exc.msg
      raise newException(Defect, exc.msg)

    return total

  T.new(
    reader = reader,
    chunkSize = chunkSize,
    pad = pad)
