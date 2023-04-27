import std/json
import std/os
import std/tables
import pkg/ethers
import pkg/questionable

import ../conf
import ./marketplace

type Deployment* = ref object
  provider: Provider
  config: CodexConf

const knownAddresses = {
 # Hardhat localhost network
 "31337": {
  "Marketplace": Address.init("0x59b670e9fA9D0A427751Af201D676719a970857b")
 }.toTable
}.toTable

proc getKnownAddress(T: type, chainId: UInt256): ?Address =
  if not ($chainId in knownAddresses):
    return none Address

  return knownAddresses[$chainId].getOrDefault($T, Address.none)

proc new*(_: type Deployment, provider: Provider, config: CodexConf): Deployment =
  Deployment(provider: provider, config: config)

proc address*(deployment: Deployment, contract: type): Future[?Address] {.async.} =
  let chainId = await deployment.provider.getChainId()
  when contract is Marketplace:
    if deployment.config.marketplaceAddress.isSome:
      return deployment.config.marketplaceAddress

  return contract.getKnownAddress(chainId)
