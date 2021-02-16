import std/sequtils
import pkg/libp2p/varint

import pkg/dagger/p2p/rng
import pkg/dagger/chunker
import pkg/dagger/blocktype

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = msg

  return buf

proc newRandomChunker*(
  rng: Rng,
  size: int64,
  kind = ChunkerType.SizedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): Chunker =
  ## create a chunker that produces
  ## random data
  ##

  var total = 0
  proc reader(data: var openArray[byte]): int =
    if total >= size:
      return 0

    var read = 0
    var alpha = toSeq(byte('A')..byte('z'))
    while read <= data.high:

      rng.shuffle(alpha)
      for a in alpha:
        if read > data.high:
          break

        data[read] = a
        read.inc

    total += read

    return read

  Chunker.new(
    kind = ChunkerType.SizedChunker,
    reader = reader,
    size = size,
    pad = pad,
    chunkSize = chunkSize)
