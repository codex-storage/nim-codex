import std/json
import std/monotimes
import std/os
import std/strutils

import pkg/chronos
import pkg/results

import ../asynctest
import ../checktest
import ../../library/node_factory

from ../../storage/storage import StorageServer, close

asyncchecksuite "Libstorage - config":
  test "rejects malformed JSON":
    let res = await createStorage("""{"log-level": "debug"""")

    check res.isErr

    if res.isErr:
      check "unable to load configuration" in res.error

  test "rejects an unknown option":
    let res = await createStorage("""{"unknown": "debug"}""")

    check res.isErr

    if res.isErr:
      check "unable to load configuration" in res.error

  test "accepts a valid config":
    let dataDir = getTempDir() / "libstorage-config" / $getMonoTime()

    defer:
      removeDir(dataDir)

    # %* escapes the path so that it can be used in JSON.
    let res = await createStorage($ %*{"data-dir": dataDir})

    check res.isOk

    if res.isOk:
      await res.get().close()
