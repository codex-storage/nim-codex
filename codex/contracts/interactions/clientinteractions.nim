import pkg/ethers
import pkg/chronicles

import ../../purchasing
import ../market
import ../clock
import ./interactions
import ../../asyncyeah

export purchasing
export chronicles

type
  ClientInteractions* = ref object of ContractInteractions
    purchasing*: Purchasing

proc new*(_: type ClientInteractions,
          clock: OnChainClock,
          purchasing: Purchasing): ClientInteractions =
  ClientInteractions(clock: clock, purchasing: purchasing)

proc start*(self: ClientInteractions) {.asyncyeah.} =
  await procCall ContractInteractions(self).start()
  await self.purchasing.start()

proc stop*(self: ClientInteractions) {.asyncyeah.} =
  await self.purchasing.stop()
  await procCall ContractInteractions(self).stop()
