import helpers/multisetup
import helpers/trackers
import helpers/templeveldb
import std/times
import std/sequtils, chronos

from std/importutils import privateAccess
# from pkg/json_rpc/rpcclient import RpcClient
# from pkg/ethers import JsonRpcProvider, JsonRpcSubscriptions
import pkg/ethers
import pkg/ethers/providers/jsonrpc/rpccalls

export multisetup, trackers, templeveldb

### taken from libp2p errorhelpers.nim
proc allFuturesThrowing*(args: varargs[FutureBase]): Future[void] =
  # This proc is only meant for use in tests / not suitable for general use.
  # - Swallowing errors arbitrarily instead of aggregating them is bad design
  # - It raises `CatchableError` instead of the union of the `futs` errors,
  #   inflating the caller's `raises` list unnecessarily. `macro` could fix it
  let futs = @args
  (
    proc() {.async: (raises: [CatchableError]).} =
      await allFutures(futs)
      var firstErr: ref CatchableError
      for fut in futs:
        if fut.failed:
          let err = fut.error()
          if err of CancelledError:
            raise err
          if firstErr == nil:
            firstErr = err
      if firstErr != nil:
        raise firstErr
  )()

proc allFuturesThrowing*[T](futs: varargs[Future[T]]): Future[void] =
  allFuturesThrowing(futs.mapIt(FutureBase(it)))

proc allFuturesThrowing*[T, E]( # https://github.com/nim-lang/Nim/issues/23432
    futs: varargs[InternalRaisesFuture[T, E]]
): Future[void] =
  allFuturesThrowing(futs.mapIt(FutureBase(it)))

# This is a workaround to manage the 5 minutes limit due to hardhat.
# See https://github.com/NomicFoundation/hardhat/issues/2053#issuecomment-1061374064
proc resubscribeWebsocketEventsOnTimeout*(ethProvider: JsonRpcProvider) {.async.} =
  privateAccess(JsonRpcProvider)
  privateAccess(JsonRpcSubscriptions)

  while true:
    await sleepAsync(5.int64.minutes)
    let subscriptions = await ethProvider.subscriptions

    for id, callback in subscriptions.callbacks:
      var newId: JsonNode
      if id in subscriptions.logFilters:
        let filter = subscriptions.logFilters[id]
        newId = await subscriptions.client.eth_subscribe("logs", filter)
        subscriptions.logFilters[newId] = filter
        subscriptions.logFilters.del(id)
      else:
        newId = await subscriptions.client.eth_subscribe("newHeads")

      subscriptions.callbacks[newId] = callback
      await subscriptions.unsubscribe(id)
