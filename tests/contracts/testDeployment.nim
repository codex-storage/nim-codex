import pkg/asynctest
import pkg/codex/conf
import pkg/codex/contracts/deployment
import pkg/codex/contracts
import ./deployment

type MockProvider = ref object of Provider
  chainId*: UInt256

method getChainId*(provider: MockProvider): Future[UInt256] {.async.} =
  return provider.chainId

suite "Deployment":

  let provider = MockProvider()

  test "uses conf value as priority":
    let deployment = Deployment.new(provider, configFactory(EthAddress.init("0x59b670e9fA9D0A427751Af201D676719a970aaaa")))
    provider.chainId = 1.u256

    let address = await deployment.address(Marketplace)
    check address.isSome
    check $(!address) == "0x59b670e9fa9d0a427751af201d676719a970aaaa"

  test "uses chainId hardcoded values as fallback":
    let deployment = Deployment.new(provider, configFactory())
    provider.chainId = 31337.u256

    let address = await deployment.address(Marketplace)
    check address.isSome
    check $(!address) == "0x59b670e9fa9d0a427751af201d676719a970857b"

  test "return none for unknown networks":
    let deployment = Deployment.new(provider, configFactory())
    provider.chainId = 1.u256

    let address = await deployment.address(Marketplace)
    check address.isNone

