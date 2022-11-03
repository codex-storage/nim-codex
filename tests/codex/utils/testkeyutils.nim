import std/unittest
import std/os
import pkg/libp2p
import pkg/questionable/results
import codex/utils/keyutils

suite "keyutils":

  let path = getTempDir() / "CodexTest"

  setup:
    createDir(path)

  teardown:
    removeDir(path)

  test "creates a key file when it does not exist yet":
    check setupKey(path / "keyfile").isSuccess
    check fileExists(path / "keyfile")

  test "reads key file when it does exist":
    let key = !setupKey(path / "keyfile")
    check !setupKey(path / "keyfile") == key

