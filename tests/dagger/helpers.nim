import pkg/libp2p/varint

import pkg/dagger/blocktype

import pkg/questionable
import pkg/questionable/results

import ./helpers/nodeutils
import ./helpers/randomchunker

export randomchunker, nodeutils

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = msg

  return buf
