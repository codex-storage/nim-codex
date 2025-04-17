import std/random
import std/sequtils
import pkg/libp2p
import pkg/nitro
import pkg/stint
import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/sales
import pkg/codex/merkletree
import pkg/codex/manifest
import ../examples

export examples

proc example*(_: type EthAddress): EthAddress =
  EthPrivateKey.random().toPublicKey.toAddress

proc example*(_: type UInt48): UInt48 =
  # workaround for https://github.com/nim-lang/Nim/issues/17670
  uint64.rand mod (UInt48.high + 1)

proc example*(_: type Wallet): Wallet =
  Wallet.init(EthPrivateKey.random())

proc example*(_: type WalletRef): WalletRef =
  WalletRef.new(EthPrivateKey.random())

proc example*(_: type SignedState): SignedState =
  var wallet = Wallet.example
  let hub, asset, receiver = EthAddress.example
  let chainId, amount = UInt256.example
  let nonce = UInt48.example
  let channel = wallet.openLedgerChannel(hub, chainId, nonce, asset, amount).get
  wallet.pay(channel, asset, receiver, amount).get

proc example*(_: type Pricing): Pricing =
  Pricing(address: EthAddress.example, price: uint32.rand.u256)

proc example*(_: type bt.Block, size: int = 4096): bt.Block =
  let length = rand(size)
  let bytes = newSeqWith(length, rand(uint8))
  bt.Block.new(bytes).tryGet()

proc example*(_: type PeerId): PeerId =
  let key = PrivateKey.random(Rng.instance[]).get
  PeerId.init(key.getPublicKey().get).get

proc example*(_: type BlockExcPeerCtx): BlockExcPeerCtx =
  BlockExcPeerCtx(id: PeerId.example)

proc example*(_: type Cid): Cid =
  bt.Block.example.cid

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

proc example*(
    _: type Availability, collateralPerByte = Tokens.init(uint8.example)
): Availability =
  let totalSize = uint16.example.uint64
  Availability.init(
    totalSize = totalSize,
    freeSize = uint16.example.uint64,
    duration = StorageDuration.init(uint16.example),
    minPricePerBytePerSecond = TokensPerSecond.init(uint8.example),
    totalCollateral = collateralPerByte * totalSize,
    enabled = true,
    until = 0'StorageTimestamp,
  )

proc example*(_: type Reservation): Reservation =
  Reservation.init(
    availabilityId = AvailabilityId(array[32, byte].example),
    size = uint16.example.uint64,
    slotId = SlotId.example,
  )

proc example*(_: type MerkleProof): MerkleProof =
  MerkleProof.init(3, @[MultiHash.example]).tryget()

proc example*(_: type Poseidon2Proof): Poseidon2Proof =
  var example = MerkleProof[Poseidon2Hash, PoseidonKeysEnum]()
  example.index = 123
  example.path = @[1, 2, 3, 4].mapIt(it.toF)
  example
