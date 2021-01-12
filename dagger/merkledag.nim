import pkg/libp2p/multihash

export multihash

type
  MerkleDag* = object
    data*: seq[byte]

proc rootHash*(dag: MerkleDag): MultiHash =
  MultiHash.digest("sha2-256", dag.data).get()
