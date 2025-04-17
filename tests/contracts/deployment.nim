import std/os
import std/options
import pkg/ethers
import pkg/codex/contracts/marketplace

const hardhatMarketAddress =
  Address.init("0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f").get()
const hardhatMarketWithDummyVerifier =
  Address.init("0x4A679253410272dd5232B3Ff7cF5dbB88f295319").get()
const marketAddressEnvName = "CODEX_MARKET_ADDRESS"

proc address*(_: type Marketplace, dummyVerifier = false): Address =
  if existsEnv(marketAddressEnvName):
    without address =? Address.init(getEnv(marketAddressEnvName)):
      raiseAssert "Invalid env. variable marketplace contract address"

    return address

  if dummyVerifier: hardhatMarketWithDummyVerifier else: hardhatMarketAddress
