import pkg/ethers
import ../clock
import ../marketplace
import ../market
import ../../asyncyeah

export clock

type
  ContractInteractions* = ref object of RootObj
    clock*: OnChainClock

method start*(self: ContractInteractions) {.asyncyeah, base.} =
  await self.clock.start()

method stop*(self: ContractInteractions) {.asyncyeah, base.} =
  await self.clock.stop()
