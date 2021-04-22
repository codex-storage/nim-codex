import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils
import ../../examples
import ../../../../dagger/bitswap/protobuf/payments

suite "pricing protobuf messages":

  let address = EthAddress.example
  let price = UInt256.example
  let pricing = Pricing(address: address, price: price)
  let message = PricingMessage.init(pricing)

  test "encodes recipient of payments":
    check message.address == @(address.toArray)

  test "encodes price per byte":
    check message.price == @(price.toBytesBE)

  test "decodes recipient of payments":
    check Pricing.init(message).?address == address.some

  test "decodes price":
    check Pricing.init(message).?price == price.some

  test "fails to decode when address has incorrect number of bytes":
    var incorrect = message
    incorrect.address.del(0)
    check Pricing.init(incorrect).isNone

  test "fails to decode when price has too many bytes":
    var incorrect = message
    incorrect.price = newSeq[byte](33)
    check Pricing.init(incorrect).isNone

suite "channel update messages":

  let state = SignedState.example
  let update = StateChannelUpdate.init(state)

  test "encodes a nitro signed state":
    check update.update == state.toJson.toBytes

  test "decodes a channel update":
    check SignedState.init(update) == state.some

  test "fails to decode incorrect channel update":
    var incorrect = update
    incorrect.update.del(0)
    check SignedState.init(incorrect).isNone
