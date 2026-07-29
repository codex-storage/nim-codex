import std/monotimes
import std/os
import std/strutils

import pkg/chronos
import pkg/results

import ../asynctest
import ../checktest
import ../../library/storage_thread_requests/requests/node_lifecycle_request

from ../../storage/storage import StorageServer

asyncchecksuite "Libstorage - config":
  var server: StorageServer

  test "rejects malformed JSON":
    let request =
      NodeLifecycleRequest.createShared(CREATE_NODE, """{"log-level": "debug"""")
    let res = await request.process(addr server)

    check res.isErr
    check "unable to load configuration" in res.error

  test "rejects an unknown option":
    let request =
      NodeLifecycleRequest.createShared(CREATE_NODE, """{"unknown": "debug"}""")
    let res = await request.process(addr server)

    check res.isErr
    check "unable to load configuration" in res.error

  test "accepts a valid config":
    let dataDir = getTempDir() / "libstorage-config" / $getMonoTime()

    defer:
      removeDir(dataDir)

    let config = """{"data-dir": "$1", "log-level": "DEBUG"}""" % [dataDir]
    let request = NodeLifecycleRequest.createShared(CREATE_NODE, config.cstring)
    let res = await request.process(addr server)

    check res.isOk

    let closeRequest = NodeLifecycleRequest.createShared(CLOSE_NODE)
    check (await closeRequest.process(addr server)).isOk
