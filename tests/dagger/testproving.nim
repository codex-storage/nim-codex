from std/times import getTime, toUnix
import pkg/asynctest
import pkg/chronos
import pkg/dagger/proving
import ./helpers/mockprooftiming
import ./examples

suite "Proving":

  var proving: Proving
  var timing: MockProofTiming

  setup:
    timing = MockProofTiming.new()
    proving = Proving.new(timing)
    proving.start()

  teardown:
    proving.stop()

  proc advanceToNextPeriod(timing: MockProofTiming) {.async.} =
    let current = await timing.getCurrentPeriod()
    timing.advanceToPeriod(current + 1)
    await sleepAsync(1.milliseconds)

  test "maintains a list of contract ids to watch":
    let id1, id2 = ContractId.example
    check proving.contracts.len == 0
    proving.add(id1)
    check proving.contracts.contains(id1)
    proving.add(id2)
    check proving.contracts.contains(id1)
    check proving.contracts.contains(id2)

  test "removes duplicate contract ids":
    let id = ContractId.example
    proving.add(id)
    proving.add(id)
    check proving.contracts.len == 1

  test "invokes callback when proof is required":
    let id = ContractId.example
    proving.add(id)
    var called: bool
    proc onProofRequired(id: ContractId) =
      called = true
    proving.onProofRequired = onProofRequired
    timing.setProofRequired(id, true)
    await timing.advanceToNextPeriod()
    check called

  test "callback receives id of contract for which proof is required":
    let id1, id2 = ContractId.example
    proving.add(id1)
    proving.add(id2)
    var callbackIds: seq[ContractId]
    proc onProofRequired(id: ContractId) =
      callbackIds.add(id)
    proving.onProofRequired = onProofRequired
    timing.setProofRequired(id1, true)
    await timing.advanceToNextPeriod()
    check callbackIds == @[id1]
    timing.setProofRequired(id1, false)
    timing.setProofRequired(id2, true)
    await timing.advanceToNextPeriod()
    check callbackIds == @[id1, id2]

  test "invokes callback when proof is about to be required":
    let id = ContractId.example
    proving.add(id)
    var called: bool
    proc onProofRequired(id: ContractId) =
      called = true
    proving.onProofRequired = onProofRequired
    timing.setProofRequired(id, false)
    timing.setProofToBeRequired(id, true)
    await timing.advanceToNextPeriod()
    check called

  test "stops watching when contract has ended":
    let id = ContractId.example
    proving.add(id)
    timing.setProofEnd(id, getTime().toUnix().u256)
    await timing.advanceToNextPeriod()
    var called: bool
    proc onProofRequired(id: ContractId) =
      called = true
    proving.onProofRequired = onProofRequired
    timing.setProofRequired(id, true)
    await timing.advanceToNextPeriod()
    check not called
