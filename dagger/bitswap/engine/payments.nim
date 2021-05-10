import std/math
import pkg/nitro
import pkg/questionable/results
import ../peercontext

export nitro
export results
export peercontext

push: {.upraises: [].}

const ChainId* = 0.u256 # invalid chain id for now
const Asset* = EthAddress.zero # invalid ERC20 asset address for now
const AmountPerChannel = (10'u64^18).u256 # 1 asset, ERC20 default is 18 decimals

func openLedgerChannel*(wallet: WalletRef,
                        hub: EthAddress,
                        asset: EthAddress): ?!ChannelId =
  wallet.openLedgerChannel(hub, ChainId, asset, AmountPerChannel)

func getOrOpenChannel(wallet: WalletRef, peer: BitswapPeerCtx): ?!ChannelId =
  if channel =? peer.paymentChannel:
    success channel
  elif pricing =? peer.pricing:
    let channel = ?wallet.openLedgerChannel(pricing.address, Asset)
    peer.paymentChannel = channel.some
    success channel
  else:
    failure "no pricing set for peer"

func pay*(wallet: WalletRef,
          peer: BitswapPeerCtx,
          amount: UInt256): ?!SignedState =
  if pricing =? peer.pricing:
    let asset = Asset
    let receiver = pricing.address
    let channel = ?wallet.getOrOpenChannel(peer)
    wallet.pay(channel, asset, receiver, amount)
  else:
    failure "no pricing set for peer"
