import std/random
import std/sequtils
import pkg/libp2p
import pkg/nitro
import pkg/dagger/p2p/rng
import pkg/dagger/bitswap/protobuf/payments
import pkg/dagger/bitswap/peercontext
import pkg/dagger/blocktype

proc example*(_: type EthAddress): EthAddress =
  EthPrivateKey.random().toPublicKey.toAddress

proc example*(_: type UInt256): UInt256 =
  var bytes: array[32, byte]
  for b in bytes.mitems:
    b = rand(byte)
  UInt256.fromBytes(bytes)

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
  Pricing(
    address: EthAddress.example,
    price: uint32.rand.u256
  )

proc example*(_: type Block): Block =
  let length = rand(4096)
  let bytes = newSeqWith(length, rand(uint8))
  Block.new(bytes)

proc example*(_: type PeerId): PeerID =
  let key = PrivateKey.random(Rng.instance[]).get
  PeerId.init(key.getKey().get).get

proc example*(_: type BitswapPeerCtx): BitswapPeerCtx =
  BitswapPeerCtx(id: PeerID.example)

proc example*(_: type Cid): Cid =
  Block.example.cid
