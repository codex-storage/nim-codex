import std/math
import pkg/nitro
import pkg/questionable/results
import ../peercontext

export nitro
export results
export peercontext

push: {.upraises: [].}

const ChainId = 0.u256 # invalid chain id for now
const AmountPerChannel = (10^18).u256 # 1 asset, ERC20 default is 18 decimals

func openLedgerChannel*(wallet: var Wallet,
                        hub: EthAddress,
                        asset: EthAddress): ?!ChannelId =
  wallet.openLedgerChannel(hub, ChainId, asset, AmountPerChannel)

func getOrOpenChannel(wallet: var Wallet, peer: BitswapPeerCtx): ?!ChannelId =
  if channel =? peer.paymentChannel:
    channel.success
  elif pricing =? peer.pricing:
    let channel = ?wallet.openLedgerChannel(pricing.address, pricing.asset)
    peer.paymentChannel = channel.some
    channel.success
  else:
    ChannelId.failure "no pricing set for peer"

func pay*(wallet: var Wallet,
          peer: BitswapPeerCtx,
          amountOfBytes: int): ?!SignedState =
  if pricing =? peer.pricing:
    let amount = amountOfBytes.u256 * pricing.price
    let asset = pricing.asset
    let receiver = pricing.address
    let channel = ?wallet.getOrOpenChannel(peer)
    wallet.pay(channel, asset, receiver, amount)
  else:
    SignedState.failure "no pricing set for peer"
