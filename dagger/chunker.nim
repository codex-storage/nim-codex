## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import ./blocktype

export blocktype

const
  DefaultChunkSize*: int64 = 1024 * 256

type
  # default reader type
  Reader* = proc(data: var openarray[byte]): int {.gcsafe, closure.}

  ChunkerType* {.pure.} = enum
    SizedChunker
    RabinChunker

  Chunker* = object of RootObj
    reader*: Reader
    size*: Natural
    case kind*: ChunkerType:
    of SizedChunker:
      chunkSize*: Natural
      pad*: bool # pad last block if less than size
    of RabinChunker:
      discard

proc getBytes*(c: Chunker): seq[byte] =
  ## returns a chunk of bytes from
  ## the instantiated chunker
  ##

  var bytes = newSeq[byte](c.chunkSize)
  let read = c.reader(bytes)

  if not c.pad:
    bytes.setLen(read)

  return bytes

iterator items*(c: Chunker): seq[byte] =
  while true:
    let chunk = c.getBytes()
    if chunk.len <= 0:
      break

    yield chunk

proc new*(
  T: type Chunker,
  kind = ChunkerType.SizedChunker,
  reader: Reader,
  size: Natural,
  chunkSize = DefaultChunkSize,
  pad = false): T =
  var chunker = Chunker(
    kind: kind,
    reader: reader,
    size: size)

  if kind == ChunkerType.SizedChunker:
    chunker.pad = pad
    chunker.chunkSize = chunkSize

  return chunker

proc newFileChunker*(
  file: File,
  kind = ChunkerType.SizedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): Chunker =
  ## create the default File chunker
  ##

  proc reader(data: var openarray[byte]): int =
    return file.readBytes(data, 0, data.len)

  Chunker.new(
    kind = ChunkerType.SizedChunker,
    reader = reader,
    size = file.getFileSize(),
    pad = pad,
    chunkSize = chunkSize)
