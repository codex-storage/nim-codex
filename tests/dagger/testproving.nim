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
    var called: bool
    proc onProofRequired() =
      called = true
    proving.onProofRequired = onProofRequired
    timing.setProofRequired(true)
    timing.advanceToNextPeriod()
    await sleepAsync(1.milliseconds)
    check called
