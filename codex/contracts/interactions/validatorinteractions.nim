import ./interactions
import ../../validation
import ../../asyncyeah

export validation

type
  ValidatorInteractions* = ref object of ContractInteractions
    validation: Validation

proc new*(_: type ValidatorInteractions,
          clock: OnChainClock,
          validation: Validation): ValidatorInteractions =
  ValidatorInteractions(clock: clock, validation: validation)

proc start*(self: ValidatorInteractions) {.asyncyeah.} =
  await procCall ContractInteractions(self).start()
  await self.validation.start()

proc stop*(self: ValidatorInteractions) {.asyncyeah.} =
  await self.validation.stop()
  await procCall ContractInteractions(self).stop()
