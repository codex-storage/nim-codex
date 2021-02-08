import pkg/libp2p/multihash
import pkg/libp2p/multicodec
import pkg/libp2p/cid

export cid

type
  Object* = object
    data*: seq[byte]

proc cid*(obj: Object): Cid =
  let codec = multiCodec("dag-pb")
  let hash =  MultiHash.digest("sha2-256", obj.data).get()
  Cid.init(CIDv0, codec, hash).get()
