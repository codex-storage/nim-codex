import std/unittest
import std/os
import pkg/libp2p
import pkg/questionable/results
import codex/utils/keyutils

when defined(windows):
  import stew/windows/acl

suite "keyutils":

  let path = getTempDir() / "CodexTest"

  setup:
    os.createDir(path)

  teardown:
    os.removeDir(path)

  test "creates a key file when it does not exist yet":
    check setupKey(path / "keyfile").isSuccess
    check fileExists(path / "keyfile")

  test "stores key in a file that's only readable by the user":
    discard !setupKey(path / "keyfile")
    when defined(posix):
      check getFilePermissions(path / "keyfile") == {fpUserRead, fpUserWrite}
    when defined(windows):
      check checkCurrentUserOnlyACL(path / "keyfile").get()

  test "reads key file when it does exist":
    let key = !setupKey(path / "keyfile")
    check !setupKey(path / "keyfile") == key

