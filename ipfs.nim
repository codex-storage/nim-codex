import pkg/chronos

type
  Ipfs* = ref object

proc create*(t: typedesc[Ipfs]): Ipfs =
  Ipfs()

proc listen*(peer: Ipfs, address: TransportAddress) =
  discard

proc connect*(peer: Ipfs, address: TransportAddress) =
  discard

proc add*(peer: Ipfs, input: File): Future[string] {.async.} =
  discard

proc get*(peer: Ipfs, identifier: string, output: File) {.async.} =
  discard

proc stop*(peer: Ipfs) =
  discard
