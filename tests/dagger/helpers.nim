import pkg/libp2p
import pkg/libp2p/varint
import pkg/dagger/blocktype

import ./helpers/nodeutils
import ./helpers/randomchunker

export randomchunker, nodeutils

# NOTE: The meaning of equality for blocks
# is changed here, because blocks are now `ref`
# types. This is only in tests!!!
func `==`*(a, b: Block): bool =
  (a.cid == b.cid) and (a.data == b.data)

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = msg

  return buf
