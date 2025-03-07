import pkg/unittest2
import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/filling
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import ../../examples
import ../../helpers

suite "sales state 'filling'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  var state: SaleFilling

  setup:
    state = SaleFilling.new()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed
