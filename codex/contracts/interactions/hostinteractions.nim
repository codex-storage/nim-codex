import pkg/ethers
import pkg/chronicles

import ../../sales
import ../../proving
import ./interactions
import ../../asyncyeah

export sales
export proving
export chronicles

type
  HostInteractions* = ref object of ContractInteractions
    sales*: Sales
    proving*: Proving

proc new*(
    _: type HostInteractions,
    clock: OnChainClock,
    sales: Sales,
    proving: Proving
): HostInteractions =
  ## Create a new HostInteractions instance
  ##
  HostInteractions(clock: clock, sales: sales, proving: proving)

method start*(self: HostInteractions) {.asyncyeah.} =
  await procCall ContractInteractions(self).start()
  await self.sales.start()
  await self.proving.start()

method stop*(self: HostInteractions) {.asyncyeah.} =
  await self.sales.stop()
  await self.proving.stop()
  await procCall ContractInteractions(self).start()
