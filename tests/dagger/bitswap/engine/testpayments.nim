import std/unittest
import pkg/dagger/bitswap/engine/payments
import ../../examples

suite "engine payments":

  let amountOfBytes = 42

  var wallet: WalletRef
  var peer: BitswapPeerCtx

  setup:
    wallet = WalletRef.example
    peer = BitswapPeerCtx.example
    peer.pricing = Pricing.example.some

  test "pays for received bytes":
    let payment = !wallet.pay(peer, amountOfBytes)
    let pricing = !peer.pricing
    let balances = payment.state.outcome.balances(Asset)
    let destination = pricing.address.toDestination
    check !balances[destination] == amountOfBytes.u256 * pricing.price

  test "no payment when no price is set":
    peer.pricing = Pricing.none
    check wallet.pay(peer, amountOfBytes).isFailure

  test "uses same channel for consecutive payments":
    let payment1, payment2 = wallet.pay(peer, amountOfBytes)
    let channel1 = payment1.?state.?channel.?getChannelId
    let channel2 = payment2.?state.?channel.?getChannelId
    check channel1 == channel2
