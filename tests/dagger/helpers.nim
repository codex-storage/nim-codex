import std/sequtils

import pkg/chronos
import pkg/libp2p/varint

import pkg/dagger/chunker
import pkg/dagger/blocktype
import pkg/dagger/rng

import pkg/questionable
import pkg/questionable/results

export chunker

type
  RandomChunker* = Chunker

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = msg

  return buf

proc new*(
  T: type RandomChunker,
  rng: Rng,
  kind = ChunkerType.FixedChunker,
  chunkSize = DefaultChunkSize,
  size: int,
  pad = false): T =
  ## create a chunker that produces
  ## random data
  ##

  var consumed = 0
  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.async, gcsafe, raises: [Defect].} =
    var alpha = toSeq(byte('A')..byte('z'))

    if consumed >= size:
      return 0

    var read = 0
    while read < len:
      rng.shuffle(alpha)
      for a in alpha:
        if read >= len:
          break

        data[read] = a
        read.inc

    consumed += read
    return read

  Chunker.new(
    kind = ChunkerType.FixedChunker,
    reader = reader,
    pad = pad,
    chunkSize = chunkSize)
