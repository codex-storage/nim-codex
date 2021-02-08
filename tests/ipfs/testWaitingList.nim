import pkg/asynctest
import pkg/chronos
import ipfs/repo/waitinglist

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

  test "timeout does nothing when item already delivered":
    let wait = list.wait("apple", 100.milliseconds)
    list.deliver("apple")
    await sleepAsync(100.milliseconds)
    check wait.finished

  test "tracks the amount of waiting futures":
    check list.count == 0
    asyncSpawn list.wait("apple", 1.minutes)
    check list.count == 1
    asyncSpawn list.wait("orange", 1.minutes)
    check list.count == 2
    asyncSpawn list.wait("apple", 1.minutes)
    check list.count == 3

  test "removes future when item is delivered":
    asyncSpawn list.wait("apple", 1.minutes)
    list.deliver("apple")
    check list.count == 0

  test "removes future after timeout":
    asyncSpawn list.wait("apple", 100.milliseconds)
    await sleepAsync(100.milliseconds)
    check list.count == 0
