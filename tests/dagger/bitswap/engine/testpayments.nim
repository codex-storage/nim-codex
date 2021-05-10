import std/unittest
import pkg/dagger/bitswap/engine/payments
import ../../examples

suite "engine payments":

  let amount = 42.u256

  var wallet: WalletRef
  var peer: BitswapPeerCtx

  setup:
    wallet = WalletRef.example
    peer = BitswapPeerCtx.example
    peer.pricing = Pricing.example.some

  test "pays for received blocks":
    let payment = !wallet.pay(peer, amount)
    let pricing = !peer.pricing
    let balances = payment.state.outcome.balances(Asset)
    let destination = pricing.address.toDestination
    check !balances[destination] == amount

  test "no payment when no price is set":
    peer.pricing = Pricing.none
    check wallet.pay(peer, amount).isFailure

  test "uses same channel for consecutive payments":
    let payment1, payment2 = wallet.pay(peer, amount)
    let channel1 = payment1.?state.?channel.?getChannelId
    let channel2 = payment2.?state.?channel.?getChannelId
    check channel1 == channel2
