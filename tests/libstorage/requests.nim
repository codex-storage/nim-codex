import std/strutils

import pkg/chronos
import pkg/results

import ../asynctest
import ../checktest
import ../../library/storage_thread_requests/requests/node_lifecycle_request
import ../../library/storage_thread_requests/requests/node_info_request
import ../../library/storage_thread_requests/requests/node_storage_request

from ../../storage/storage import StorageServer

asyncchecksuite "Libstorage - request on a node that is not created":
  var uncreated: StorageServer

  test "rejects a start":
    let res =
      await NodeLifecycleRequest.createShared(START_NODE).process(addr uncreated)

    check res.isErr and "not created" in res.error

  test "rejects a stop":
    let res = await NodeLifecycleRequest.createShared(STOP_NODE).process(addr uncreated)

    check res.isErr and "not created" in res.error

  test "rejects a close":
    let res =
      await NodeLifecycleRequest.createShared(CLOSE_NODE).process(addr uncreated)

    check res.isErr and "not created" in res.error

  test "rejects an info request":
    let res =
      await NodeInfoRequest.createShared(NodeInfoMsgType.SPR).process(addr uncreated)

    check res.isErr and "not created" in res.error

  test "rejects a storage list request":
    let res = await NodeStorageRequest.createShared(NodeStorageMsgType.LIST).process(
      addr uncreated
    )

    check res.isErr and "not created" in res.error
