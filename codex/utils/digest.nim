import pkg/libp2p/multihash

template bytes*(mh: MultiHash): seq[byte] =
  ## get the hash bytes of a multihash object
  ##

  mh.data.buffer[mh.dpos..(mh.dpos + mh.size - 1)]
