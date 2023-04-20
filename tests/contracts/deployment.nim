import std/os
import pkg/ethers

const hardhatMarketAddress = Address.init("0x59b670e9fA9D0A427751Af201D676719a970857b").get()
const marketAddressEnvName = "CODEX_MARKET_ADDRESS"

proc marketAddress*(): Address =
  if existsEnv(marketAddressEnvName):
    let address = Address.init(getEnv(marketAddressEnvName))

    if address.isNone:
      raiseAssert "Invalid env. variable marketplace contract address"

    return address.get()

  hardhatMarketAddress
