import std/os
import std/tables
import pkg/ethers
import pkg/questionable

import ../conf
import ../logutils
import ./marketplace

type Deployment* = ref object
  provider: Provider
  marketplaceAddressOverride: ?Address

const knownAddresses = {
  # Hardhat localhost network
  "31337":
    {"Marketplace": Address.init("0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44")}.toTable,
  # Taiko Alpha-3 Testnet
  "167005":
    {"Marketplace": Address.init("0x948CF9291b77Bd7ad84781b9047129Addf1b894F")}.toTable,
  # Codex Testnet - Jun 19 2025 13:11:56 PM (+00:00 UTC)
  "789987":
    {"Marketplace": Address.init("0x5378a4EA5dA2a548ce22630A3AE74b052000C62D")}.toTable,
}.toTable

proc getKnownAddress(T: type, chainId: UInt256): ?Address =
  let id = chainId.toString(10)
  notice "Looking for well-known contract address with ChainID ", chainId = id

  if not (id in knownAddresses):
    return none Address

  return knownAddresses[id].getOrDefault($T, Address.none)

proc new*(
    _: type Deployment,
    provider: Provider,
    marketplaceAddressOverride: ?Address = none Address,
): Deployment =
  Deployment(provider: provider, marketplaceAddressOverride: marketplaceAddressOverride)

proc address*(deployment: Deployment, contract: type): Future[?Address] {.async.} =
  when contract is Marketplace:
    if address =? deployment.marketplaceAddressOverride:
      return some address

  let chainId = await deployment.provider.getChainId()
  return contract.getKnownAddress(chainId)
