import std/sequtils
import std/random
import pkg/libp2p
import pkg/dagger/obj

proc example*(t: type seq[byte]): seq[byte] =
  newSeqWith(10, rand(byte))

proc example*(t: type Object): Object =
  Object(data: seq[byte].example)

proc example*(t: type Cid): Cid =
  Object.example.cid
