import pkg/libp2p

type
  MerkleDag* = object
    data*: seq[byte]

proc rootId*(dag: MerkleDag): Cid =
  let codec = multiCodec("dag-pb")
  let hash =  MultiHash.digest("sha2-256", dag.data).get()
  Cid.init(CIDv0, codec, hash).get()
