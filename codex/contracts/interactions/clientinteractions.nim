import pkg/ethers
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results

import ../../purchasing
import ../deployment
import ../marketplace
import ../market
import ../proofs
import ../clock
import ./interactions

export purchasing
export chronicles

type
  ClientInteractions* = ref object of ContractInteractions
    purchasing*: Purchasing

proc new*(_: type ClientInteractions,
          signer: Signer,
          deployment: Deployment): ?!ClientInteractions =

  without prepared =? prepare(signer, deployment), error:
    return failure(error)

  let c = ClientInteractions.new(prepared.clock)
  c.purchasing = Purchasing.new(prepared.market, prepared.clock)
  return success(c)

proc new*(_: type ClientInteractions,
          providerUrl: string,
          account: Address,
          deploymentFile: ?string = none string): ?!ClientInteractions =

  without prepared =? prepare(providerUrl, account, deploymentFile), error:
    return failure(error)

  return ClientInteractions.new(prepared.signer, prepared.deploy)

proc new*(_: type ClientInteractions,
          account: Address): ?!ClientInteractions =
  ClientInteractions.new("ws://localhost:8545", account)

proc start*(self: ClientInteractions) {.async.} =
  await procCall ContractInteractions(self).start()
  await self.purchasing.start()

proc stop*(self: ClientInteractions) {.async.} =
  await self.purchasing.stop()
  await procCall ContractInteractions(self).stop()
