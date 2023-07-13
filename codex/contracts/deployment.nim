import std/json
import std/os
import std/tables
import pkg/ethers
import pkg/questionable
import pkg/chronicles

import ../conf
import ./marketplace

type Deployment* = ref object
  provider: Provider
  config: CodexConf

const knownAddresses = {
 # Hardhat localhost network
 "31337": {
  "Marketplace": Address.init("0x59b670e9fA9D0A427751Af201D676719a970857b")
 }.toTable,
 # Taiko Alpha-3 Testnet
 "167005": {
  "Marketplace": Address.init("0xDB2a8A1c8Df776F1C544a56a7734a865ad1C05e8")
 }.toTable
}.toTable

proc getKnownAddress(T: type, chainId: UInt256): ?Address =
  let id = chainId.toString(10)
  notice "Looking for well-known contract address with ChainID ", chainId=id

  if not (id in knownAddresses):
    return none Address

  return knownAddresses[id].getOrDefault($T, Address.none)

proc new*(_: type Deployment, provider: Provider, config: CodexConf): Deployment =
  Deployment(provider: provider, config: config)

proc address*(deployment: Deployment, contract: type): Future[?Address] {.async.} =
  when contract is Marketplace:
    if address =? deployment.config.marketplaceAddress:
      return some address

  let chainId = await deployment.provider.getChainId()
  return contract.getKnownAddress(chainId)
