import std/strutils
import pkg/chronicles
import pkg/ethers
import pkg/ethers/testing
import ../market
import ../clock
import ./proving

type
  SimulatedProving* = ref object of Proving
    failEveryNProofs: uint
    proofCount: uint

func new*(_: type SimulatedProving,
          market: Market,
          clock: Clock,
          failEveryNProofs: uint): SimulatedProving =

  let p = SimulatedProving.new(market, clock)
  p.failEveryNProofs = failEveryNProofs
  return p

method init(proving: SimulatedProving) {.async.} =
  if proving.failEveryNProofs > 0'u and await proving.market.isMainnet():
    warn "Connected to mainnet, simulated proof failures will not be run. " &
         "Consider changing the value of --simulate-proof-failures and/or " &
         "--eth-provider."
    proving.failEveryNProofs = 0'u

proc onSubmitProofError(error: ref CatchableError) =
  error "Submitting invalid proof failed", msg = error.msg

method prove(proving: SimulatedProving, slot: Slot) {.async.} =
  proving.proofCount += 1
  if proving.failEveryNProofs > 0'u and
     proving.proofCount mod proving.failEveryNProofs == 0'u:
    proving.proofCount = 0
    try:
      await proving.market.submitProof(slot.id, newSeq[byte](0))
    except ProviderError as e:
      if not e.revertReason.contains("Invalid proof"):
        onSubmitProofError(e)
    except CatchableError as e:
      onSubmitProofError(e)
  else:
    await procCall Proving(proving).prove(slot)

