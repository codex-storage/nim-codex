import pkg/ethers
import pkg/chronicles

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
          repoStore: RepoStore): ?HostInteractions =

  without address =? deployment.address(Marketplace):
    error "Unable to determine address of the Marketplace smart contract"
    return none HostInteractions

  let contract = Marketplace.new(address, signer)
  let market = OnChainMarket.new(contract)
  let proofs = OnChainProofs.new(contract)
  let clock = OnChainClock.new(signer.provider)
  let proving = Proving.new(proofs, clock)

  let h = HostInteractions.new(clock)
  h.sales = Sales.new(market, clock, proving, repoStore)
  h.proving = proving
  some h

proc new*(_: type HostInteractions,
          providerUrl: string,
          account: Address,
          repo: RepoStore,
          deploymentFile: string = string.default): ?HostInteractions =

  without prepared =? prepare(providerUrl, account, deploymentFile):
    return none HostInteractions

  HostInteractions.new(prepared.signer, prepared.deploy, repo)

proc new*(_: type HostInteractions,
          account: Address,
          repo: RepoStore): ?HostInteractions =
  HostInteractions.new("ws://localhost:8545", account, repo)

method start*(self: HostInteractions) {.async.} =
  await self.sales.start()
  await self.proving.start()
  await procCall ContractInteractions(self).start()

method stop*(self: HostInteractions) {.async.} =
  await self.sales.stop()
  await self.proving.stop()
  await procCall ContractInteractions(self).start()
