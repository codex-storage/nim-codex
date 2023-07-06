import std/unittest
import ./nodes

suite "Command line interface":

  test "complains when persistence is enabled without ethereum account":
    let node = startNode(@["--persistence"])
    node.waitUntilOutput("Persistence enabled, but no Ethereum account was set")
    node.stop()

  test "complains when validator is enabled without ethereum account":
    let node = startNode(@["--validator"])
    node.waitUntilOutput("Validator enabled, but no Ethereum account was set")
    node.stop()

  test "complains when ethereum account is set when not needed":
    let account = "4242424242424242424242424242424242424242"
    let node = startNode(@["--eth-account=" & account])
    node.waitUntilOutput("Ethereum account was set, but neither persistence nor validator is enabled")
    node.stop()

  test "complains when ethereum private key is set when not needed":
    let key = "4242424242424242424242424242424242424242424242424242424242424242"
    let node = startNode(@["--eth-private-key=" & key])
    node.waitUntilOutput("Ethereum account was set, but neither persistence nor validator is enabled")
    node.stop()
