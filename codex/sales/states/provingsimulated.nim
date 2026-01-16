import ../../conf
when storage_enable_proof_failures:
  import std/strutils
  import pkg/stint
  import pkg/ethers

  import ../../contracts/marketplace
  import ../../contracts/requests
  import ../../logutils
  import ../../market
  import ../../utils/exceptions
  import ../salescontext
  import ./proving
  import ./errored

  logScope:
    topics = "marketplace sales simulated-proving"

  type SaleProvingSimulated* = ref object of SaleProving
    failEveryNProofs*: int
    proofCount: int

  proc onSubmitProofError(error: ref CatchableError, period: Period, slotId: SlotId) =
    error "Submitting invalid proof failed", period, slotId, msg = error.msgDetail

  method prove*(
      state: SaleProvingSimulated,
      slot: Slot,
      challenge: ProofChallenge,
      onProve: OnProve,
      market: Market,
      currentPeriod: Period,
  ) {.async.} =
    try:
      trace "Processing proving in simulated mode"
      state.proofCount += 1
      if state.failEveryNProofs > 0 and state.proofCount mod state.failEveryNProofs == 0:
        state.proofCount = 0

        try:
          warn "Submitting INVALID proof", period = currentPeriod, slotId = slot.id
          await market.submitProof(slot.id, Groth16Proof.default)
        except ProofInvalidError as e:
          discard # expected
        except CancelledError as error:
          raise error
        except CatchableError as e:
          onSubmitProofError(e, currentPeriod, slot.id)
      else:
        await procCall SaleProving(state).prove(
          slot, challenge, onProve, market, currentPeriod
        )
    except CancelledError as e:
      trace "Submitting INVALID proof cancelled", error = e.msgDetail
      raise e
    except CatchableError as e:
      error "Submitting INVALID proof failed", error = e.msgDetail
