import pkg/asynctest
import pkg/chronos
import pkg/dagger/repo/waitinglist

suite "waiting list":

  var list: WaitingList[string]

  setup:
    list = WaitingList[string]()

  test "waits for item to be delivered":
    let waiting = list.wait("apple", 1.minutes)
    check not waiting.finished
    list.deliver("orange")
    check not waiting.finished
    list.deliver("apple")
    check waiting.finished

  test "notifies everyone who is waiting":
    let wait1 = list.wait("apple", 1.minutes)
    let wait2 = list.wait("apple", 1.minutes)
    list.deliver("apple")
    check wait1.finished
    check wait2.finished

  test "stops waiting after timeout":
    let wait = list.wait("apple", 100.milliseconds)
    check not wait.finished
    await sleepAsync(100.milliseconds)
    check wait.finished
