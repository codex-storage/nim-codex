import pkg/ethers
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results

import ../../sales
import ../../proving
import ../../stores
import ../deployment
import ../marketplace
import ../market
import ../proofs
import ../clock
import ./interactions

export sales
export proving
export chronicles

type
  HostInteractions* = ref object of ContractInteractions
    sales*: Sales
    proving*: Proving

proc new*(_: type HostInteractions,
          signer: Signer,
          deployment: Deployment,
          repoStore: RepoStore): ?!HostInteractions =

  without address =? deployment.address(Marketplace):
    let err = newException(ContractAddressError,
      "Unable to determine address of the Marketplace smart contract")
    return failure(err)

  let contract = Marketplace.new(address, signer)
  let market = OnChainMarket.new(contract)
  let proofs = OnChainProofs.new(contract)
  let clock = OnChainClock.new(signer.provider)
  let proving = Proving.new(proofs, clock)

  let h = HostInteractions.new(clock)
  h.sales = Sales.new(market, clock, proving, repoStore)
  h.proving = proving
  return success(h)

proc new*(_: type HostInteractions,
  providerUrl: string,
  account: Address,
  repo: RepoStore,
  deploymentFile: ?string = string.none): ?!HostInteractions =

  without prepared =? prepare(providerUrl, account, deploymentFile), error:
    return failure(error)

  return HostInteractions.new(prepared.signer, prepared.deploy, repo)

proc new*(_: type HostInteractions,
          account: Address,
          repo: RepoStore): ?!HostInteractions =
  HostInteractions.new("ws://localhost:8545", account, repo)

method start*(self: HostInteractions) {.async.} =
  await procCall ContractInteractions(self).start()
  await self.sales.start()
  await self.proving.start()

method stop*(self: HostInteractions) {.async.} =
  await self.sales.stop()
  await self.proving.stop()
  await procCall ContractInteractions(self).start()
