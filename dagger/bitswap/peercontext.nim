import std/sequtils
import pkg/libp2p
import pkg/chronos
import pkg/questionable
import ./protobuf/bitswap
import ./protobuf/payments

type
  BitswapPeerCtx* = ref object of RootObj
    id*: PeerID
    peerHave*: seq[Cid]     # remote peers have lists
    peerWants*: seq[Entry]  # remote peers want lists
    bytesSent*: int         # bytes sent to remote
    bytesRecv*: int         # bytes received from remote
    exchanged*: int         # times peer has exchanged with us
    lastExchange*: Moment   # last time peer has exchanged with us
    pricing*: ?Pricing      # optional bandwidth price for this peer

proc contains*(a: openArray[BitswapPeerCtx], b: PeerID): bool =
  ## Convenience method to check for peer prepense
  ##

  a.anyIt( it.id == b )

proc debtRatio*(b: BitswapPeerCtx): float =
  b.bytesSent / (b.bytesRecv + 1)

proc `<`*(a, b: BitswapPeerCtx): bool =
  a.debtRatio < b.debtRatio

