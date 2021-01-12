import pkg/chronos

type
  DaggerPeer* = ref object

proc newDaggerPeer*: DaggerPeer =
  DaggerPeer()

proc listen*(peer: DaggerPeer, address: TransportAddress) =
  discard

proc dial*(peer: DaggerPeer, address: TransportAddress) =
  discard

proc upload*(peer: DaggerPeer, input: File): Future[string] {.async.} =
  discard

proc download*(peer: DaggerPeer, identifier: string, output: File) {.async.} =
  discard

proc close*(peer: DaggerPeer) =
  discard
