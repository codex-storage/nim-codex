import pkg/libp2p
import ../protobuf/bitswap

export Cid
export Message

proc want*(t: type Message, cids: varargs[Cid]): Message =
  for cid in cids:
    let entry = Entry(`block`: cid.data.buffer)
    result.wantlist.entries.add(entry)

proc send*(t: type Message, blocks: varargs[seq[byte]]): Message =
  for data in blocks:
    let bloc = Block(data: data)
    result.payload.add(bloc)
