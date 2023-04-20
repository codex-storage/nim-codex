import std/json
import std/os
import std/tables
import pkg/ethers
import pkg/questionable

import ../conf

type Deployment* = ref object
  provider: Provider
  config: CodexConf

const knownAddresses = {
 # Hardhat localhost network
 "31337": {
  "Marketplace": Address.init("0x59b670e9fA9D0A427751Af201D676719a970857b")
 }.toTable
}.toTable

proc getKnownAddress(chainId: UInt256, contractName: string): ?Address =
  if not ($chainId in knownAddresses):
    return none Address

  return knownAddresses[$chainId].getOrDefault(contractName, Address.none)

proc new*(_: type Deployment, provider: Provider, config: CodexConf): Deployment =
  Deployment(provider: provider, config: config)

proc address*(deployment: Deployment, contract: typedesc): Future[?Address] {.async.} =
  let
    contractName = $contract
    chainId = await deployment.provider.getChainId()

  case contractName:
    of "Marketplace":
      if deployment.config.marketplaceAddress.isSome:
        return deployment.config.marketplaceAddress.get.some

  return getKnownAddress(chainId, contractName)
