import std/os
import std/options
import pkg/ethers
import pkg/codex/contracts/marketplace

const hardhatMarketAddress = Address.init("0x59b670e9fA9D0A427751Af201D676719a970857b").get()
const marketAddressEnvName = "CODEX_MARKET_ADDRESS"

proc address*(_: type Marketplace): Address =
  if existsEnv(marketAddressEnvName):
    without address =? Address.init(getEnv(marketAddressEnvName)):
      raiseAssert "Invalid env. variable marketplace contract address"

    return address

  hardhatMarketAddress

proc configFactory*(): CodexConf =
  CodexConf(cmd: noCommand,
            nat: ValidIpAddress.init("127.0.0.1"),
            discoveryIp: ValidIpAddress.init(IPv4_any()),
            metricsAddress: ValidIpAddress.init("127.0.0.1"))

proc configFactory*(marketplace: Option[EthAddress]): CodexConf =
  CodexConf(cmd: noCommand,
            nat: ValidIpAddress.init("127.0.0.1"),
            discoveryIp: ValidIpAddress.init(IPv4_any()),
            metricsAddress: ValidIpAddress.init("127.0.0.1"),
            marketplaceAddress: marketplace)
