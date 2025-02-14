import pkg/chronos

# proc fut(sleep: int, raiz = false) {.async.} =
#   await sleepAsync(sleep.millis)
#   if raiz:
#     raise newException(ValueError, "some error")

# proc run() {.async.} =
#   let fut1 = fut(1)
#   let fut2 = fut(2, true)

#   # discard await race(fut1, fut2)
#   let winner = await race(fut1, fut2)
#   await Future[void](winner)

# waitFor run()

proc myFut() {.async.} =
  echo "myFut"
  try:
    await sleepAsync(10.seconds)
  except CancelledError:
    echo "myFut was cancelled"

proc runMe() {.async.} =
  let f = myFut()
  await f.cancelAndWait()
  echo "myFut.state: ", f.state

waitFor runMe()
