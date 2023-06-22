import ../conf
when codex_enable_proof_failures:

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

  logScope:
    topics = "simulated proving"

  func new*(_: type SimulatedProving,
            market: Market,
            clock: Clock,
            failEveryNProofs: uint): SimulatedProving =

    let p = SimulatedProving.new(market, clock)
    p.failEveryNProofs = failEveryNProofs
    return p

  proc onSubmitProofError(error: ref CatchableError, period: UInt256) =
    error "Submitting invalid proof failed", period, msg = error.msg

  method prove(proving: SimulatedProving, slot: Slot) {.async.} =
    let period = await proving.getCurrentPeriod()
    proving.proofCount += 1
    if proving.failEveryNProofs > 0'u and
      proving.proofCount mod proving.failEveryNProofs == 0'u:
      proving.proofCount = 0
      try:
        trace "submitting INVALID proof", currentPeriod = await proving.getCurrentPeriod()
        await proving.market.submitProof(slot.id, newSeq[byte](0))
      except ProviderError as e:
        if not e.revertReason.contains("Invalid proof"):
          onSubmitProofError(e, period)
      except CatchableError as e:
        onSubmitProofError(e, period)
    else:
      await procCall Proving(proving).prove(slot)
