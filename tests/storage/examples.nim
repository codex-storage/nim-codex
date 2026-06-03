import std/[random, sequtils]

import pkg/libp2p
import pkg/stint
import pkg/storage/rng
import pkg/storage/stores
import pkg/storage/blocktype as bt
import pkg/storage/merkletree
import pkg/storage/manifest
import ../examples

export examples

proc example*(_: type bt.Block, size: int = 4096): bt.Block =
  let bytes = newSeqWith(size, rand(uint8))
  bt.Block.new(bytes).tryGet()

proc example*(_: type PeerId): PeerId =
  let key = PrivateKey.random(Rng.instance).get
  PeerId.init(key.getPublicKey().get).get

proc example*(_: type PeerContext): PeerContext =
  PeerContext(id: PeerId.example)

proc example*(_: type Cid): Cid =
  bt.Block.example.cid

proc example*(_: type BlockAddress): BlockAddress =
  BlockAddress.init(Cid.example, 0)

proc example*(_: type Manifest): Manifest =
  Manifest.new(
    treeCid = Cid.example,
    blockSize = 256.NBytes,
    datasetSize = 4096.NBytes,
    filename = "example.txt".some,
    mimetype = "text/plain".some,
  )

proc example*(_: type MultiHash, mcodec = Sha256HashCodec): MultiHash =
  let bytes = newSeqWith(256, rand(uint8))
  MultiHash.digest($mcodec, bytes).tryGet()

proc example*(_: type MerkleProof): MerkleProof =
  MerkleProof.init(3, @[MultiHash.example]).tryget()
