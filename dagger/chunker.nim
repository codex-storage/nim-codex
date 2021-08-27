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

import ./rng
import ./blocktype

export blocktype

const
  DefaultChunkSize*: int64 = 1024 * 256

type
  # default reader type
  Reader* =
    proc(data: var openArray[byte], offset: Natural = 0): int
    {.gcsafe, closure, raises: [Defect].}

  ChunkerType* {.pure.} = enum
    SizedChunker
    RabinChunker

  Chunker* = ref object of RootObj
    reader*: Reader
    size*: Natural
    pos*: Natural
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

  if c.pos >= c.size:
    return

  var bytes = newSeq[byte](c.chunkSize)
  let read = c.reader(bytes, c.pos)
  c.pos += read

  if not c.pad and bytes.len != read:
    bytes.setLen(read)

  return bytes

iterator items*(c: Chunker): seq[byte] =
  while true:
    let chunk = c.getBytes()
    if chunk.len <= 0:
      break

    yield chunk

func new(
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

proc newRandomChunker*(
  rng: Rng,
  size: int64,
  kind = ChunkerType.SizedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): Chunker =
  ## create a chunker that produces
  ## random data
  ##

  proc reader(data: var openArray[byte], offset: Natural = 0): int =
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
    kind = ChunkerType.SizedChunker,
    reader = reader,
    size = size,
    pad = pad,
    chunkSize = chunkSize)

proc newFileChunker*(
  file: File,
  kind = ChunkerType.SizedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): Chunker =
  ## create the default File chunker
  ##

  proc reader(data: var openArray[byte], offset: Natural = 0): int =
    try:
      return file.readBytes(data, 0, data.len)
    except IOError as exc:
      # TODO: revisit error handling - should this be fatal?
      raise newException(Defect, exc.msg)

  Chunker.new(
    kind = ChunkerType.SizedChunker,
    reader = reader,
    size = try: file.getFileSize() except: 0, # TODO: should do something smarter abou this
    pad = pad,
    chunkSize = chunkSize)
