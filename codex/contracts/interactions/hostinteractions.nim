import pkg/ethers
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results

import ../../sales
import ../../proving
import ../../stores
import ../proofs
import ./interactions

export sales
export proving
export chronicles

type
  HostInteractions* = ref object of ContractInteractions
    sales*: Sales
    proving*: Proving

proc new*(_: type HostInteractions,
  providerUrl: string,
  account: Address,
  repo: RepoStore,
  contractAddress: Address): ?!HostInteractions =

  without prepared =? prepare(providerUrl, account, contractAddress), error:
    return failure(error)

  let proofs = OnChainProofs.new(prepared.contract)
  let proving = Proving.new(proofs, prepared.clock)

  let h = HostInteractions.new(prepared.clock)
  h.sales = Sales.new(prepared.market, prepared.clock, proving, repo)
  h.proving = proving
  return success(h)

method start*(self: HostInteractions) {.async.} =
  await procCall ContractInteractions(self).start()
  await self.sales.start()
  await self.proving.start()

method stop*(self: HostInteractions) {.async.} =
  await self.sales.stop()
  await self.proving.stop()
  await procCall ContractInteractions(self).start()
