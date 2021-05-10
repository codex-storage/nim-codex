import std/sequtils
import std/tables
import pkg/libp2p
import pkg/chronos
import pkg/nitro
import pkg/questionable
import ./protobuf/bitswap
import ./protobuf/payments
import ./protobuf/presence

export payments
export nitro

type
  BitswapPeerCtx* = ref object of RootObj
    id*: PeerID
    peerPrices*: Table[Cid, UInt256] # remote peer have list including price
    peerWants*: seq[Entry]      # remote peers want lists
    exchanged*: int             # times peer has exchanged with us
    lastExchange*: Moment       # last time peer has exchanged with us
    pricing*: ?Pricing          # optional bandwidth price for this peer
    paymentChannel*: ?ChannelId # payment channel id

proc peerHave*(context: BitswapPeerCtx): seq[Cid] =
  toSeq(context.peerPrices.keys)

proc contains*(a: openArray[BitswapPeerCtx], b: PeerID): bool =
  ## Convenience method to check for peer prepense
  ##

  a.anyIt( it.id == b )

func updatePresence*(context: BitswapPeerCtx, presence: Presence) =
  let cid = presence.cid
  let price = presence.price

  if cid notin context.peerHave and presence.have:
    context.peerPrices[cid] = price
  elif cid in context.peerHave and not presence.have:
    context.peerPrices.del(cid)

func price*(context: BitswapPeerCtx, cids: seq[Cid]): UInt256 =
  for cid in cids:
    if price =? context.peerPrices.?[cid]:
      result += price
