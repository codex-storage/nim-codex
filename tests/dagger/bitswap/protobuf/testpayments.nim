import pkg/asynctest
import pkg/chronos
import ../../examples
import ../../../../dagger/bitswap/protobuf/payments

suite "pricing protobuf messages":

  let address = EthAddress.example
  let asset = EthAddress.example
  let price = UInt256.example
  let pricing = Pricing(address: address, asset: asset, price: price)
  let message = PricingMessage.init(pricing)

  test "encodes recipient of payments":
    check message.address == @(address.toArray)

  test "encodes address of asset":
    check message.asset == @(asset.toArray)

  test "encodes price per byte":
    check message.price == @(price.toBytesBE)

  test "decodes recipient of payments":
    check Pricing.init(message)?.address == address.some

  test "decodes address of asset":
    check Pricing.init(message)?.asset == asset.some

  test "decodes price":
    check Pricing.init(message)?.price == price.some

  test "fails to decode when address has incorrect number of bytes":
    var incorrect = message
    incorrect.address.del(0)
    check Pricing.init(incorrect).isNone

  test "fails to decode when asset has incorrect number of bytes":
    var incorrect = message
    incorrect.asset.del(0)
    check Pricing.init(incorrect).isNone

  test "fails to decode when price has too many bytes":
    var incorrect = message
    incorrect.price = newSeq[byte](33)
    check Pricing.init(incorrect).isNone
