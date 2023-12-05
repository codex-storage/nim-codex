import pkg/ethers
import pkg/chronicles

import ../../purchasing
import ../market
import ../clock
import ./interactions

export purchasing
export chronicles except toJson

type
  ClientInteractions* = ref object of ContractInteractions
    purchasing*: Purchasing

proc new*(_: type ClientInteractions,
          clock: OnChainClock,
          purchasing: Purchasing): ClientInteractions =
  ClientInteractions(clock: clock, purchasing: purchasing)

proc start*(self: ClientInteractions) {.async.} =
  await procCall ContractInteractions(self).start()
  await self.purchasing.start()

proc stop*(self: ClientInteractions) {.async.} =
  await self.purchasing.stop()
  await procCall ContractInteractions(self).stop()
