import ../../conf
when codex_enable_proof_failures:
  import std/strutils
  import pkg/stint
  import pkg/ethers
  import pkg/ethers/testing

  import ../../contracts/requests
  import ../../logging
  import ../../market
  import ../salescontext
  import ./proving

  logScope:
      topics = "marketplace sales simulated-proving"

  type
    SaleProvingSimulated* = ref object of SaleProving
      failEveryNProofs*: int
      proofCount: int

  proc onSubmitProofError(error: ref CatchableError, period: UInt256, slotId: SlotId) =
    error "Submitting invalid proof failed", period = period, slotId, msg = error.msg

  method prove*(state: SaleProvingSimulated, slot: Slot, challenge: ProofChallenge, onProve: OnProve, market: Market, currentPeriod: Period) {.async.} =
    trace "Processing proving in simulated mode"
    state.proofCount += 1
    if state.failEveryNProofs > 0 and
      state.proofCount mod state.failEveryNProofs == 0:
      state.proofCount = 0

      try:
        warn "Submitting INVALID proof", period = currentPeriod, slotId = slot.id
        await market.submitProof(slot.id, newSeq[byte](0))
      except ProviderError as e:
        if not e.revertReason.contains("Invalid proof"):
          onSubmitProofError(e, currentPeriod, slot.id)
      except CatchableError as e:
        onSubmitProofError(e, currentPeriod, slot.id)
    else:
      await procCall SaleProving(state).prove(slot, challenge, onProve, market, currentPeriod)
