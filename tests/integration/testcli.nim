import std/unittest
import std/tempfiles
import codex/utils/fileutils
import ./nodes

suite "Command line interface":

  let account = "4242424242424242424242424242424242424242"
  let key = "4242424242424242424242424242424242424242424242424242424242424242"

  test "complains when persistence is enabled without ethereum account":
    let node = startNode(@["--persistence"])
    node.waitUntilOutput("Persistence enabled, but no Ethereum account was set")
    node.stop()

  test "complains when validator is enabled without ethereum account":
    let node = startNode(@["--validator"])
    node.waitUntilOutput("Validator enabled, but no Ethereum account was set")
    node.stop()

  test "complains when ethereum account is set when not needed":
    let node = startNode(@["--eth-account=" & account])
    node.waitUntilOutput("Ethereum account was set, but neither persistence nor validator is enabled")
    node.stop()

  test "complains when ethereum private key is set when not needed":
    let keyFile = genTempPath("", "")
    discard secureWriteFile(keyFile, key)
    let node = startNode(@["--eth-private-key=" & keyFile])
    node.waitUntilOutput("Ethereum account was set, but neither persistence nor validator is enabled")
    node.stop()
    discard removeFile(keyFile)

  test "complains when ethereum private key file has wrong permissions":
    let unsafeKeyFile = genTempPath("", "")
    discard unsafeKeyFile.writeFile(key, 0o666)
    let node = startNode(@["--persistence", "--eth-private-key=" & unsafeKeyFile])
    node.waitUntilOutput("Ethereum private key file does not have safe file permissions")
    node.stop()
    discard removeFile(unsafeKeyFile)
