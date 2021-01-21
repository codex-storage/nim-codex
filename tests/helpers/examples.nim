import std/sequtils
import std/random
import pkg/libp2p
import pkg/ipfs/ipfsobject

proc example*(t: type seq[byte]): seq[byte] =
  newSeqWith(10, rand(byte))

proc example*(t: type IpfsObject): IpfsObject =
  IpfsObject(data: seq[byte].example)

proc example*(t: type Cid): Cid =
  IpfsObject.example.cid
