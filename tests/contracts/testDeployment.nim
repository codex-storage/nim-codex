import pkg/ethers
import pkg/questionable
import codex/contracts/deployment
import codex/contracts

import ../asynctest
import ../checktest

type MockProvider = ref object of Provider
  chainId*: UInt256

method getChainId*(
    provider: MockProvider
): Future[UInt256] {.async: (raises: [ProviderError, CancelledError]).} =
  return provider.chainId

asyncchecksuite "Deployment":
  let provider = MockProvider()

  test "uses conf value as priority":
    let deployment = Deployment.new(
      provider, some !Address.init("0x59b670e9fA9D0A427751Af201D676719a970aaaa")
    )
    provider.chainId = 1.u256

    let address = await deployment.address(Marketplace)
    check address.isSome
    check $(!address) == "0x59b670e9fa9d0a427751af201d676719a970aaaa"

  test "uses chainId hardcoded values as fallback":
    let deployment = Deployment.new(provider)
    provider.chainId = 167005.u256

    let address = await deployment.address(Marketplace)
    check address.isSome
    check $(!address) == "0x948cf9291b77bd7ad84781b9047129addf1b894f"

  test "return none for unknown networks":
    let deployment = Deployment.new(provider)
    provider.chainId = 1.u256

    let address = await deployment.address(Marketplace)
    check address.isNone
