import pkg/libp2p/varint

import pkg/dagger/chunker
import pkg/dagger/blocktype
import pkg/dagger/blockstream

import pkg/questionable
import pkg/questionable/results

export chunker

type
  TestStreamProc* = proc(): ?!Block {.raises: [Defect].}

  TestStream* = ref object of BlockStreamRef
    handler*: TestStreamProc

method nextBlock*(b: TestStream): ?!Block =
  b.handler()

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = msg

  return buf
