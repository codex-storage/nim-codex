import std/unittest
import std/tempfiles
import codex/conf
import codex/utils/fileutils
import ./nodes

suite "Command line interface":

  let key = "4242424242424242424242424242424242424242424242424242424242424242"

  test "complains when persistence is enabled without accessible r1cs file":
    let node = startNode(@["persistence"])
    node.waitUntilOutput("Circom R1CS file not accessible")
    node.stop()

  test "complains when persistence is enabled without accessible wasm file":
    let node = startNode(@[
      "persistence",
      "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs"
    ])
    node.waitUntilOutput("wasm file not readable, doesn't exist or wrong extension (.wasm)")
    node.stop()

  test "complains when persistence is enabled without accessible zkey file":
    let node = startNode(@[
      "persistence",
      "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
      "--circom-wasm=tests/circuits/fixtures/proof_main.wasm"
    ])
    node.waitUntilOutput("zkey file not readable, doesn't exist or wrong extension (.zkey)")
    node.stop()

  test "complains when persistence is enabled without ethereum account":
    let node = startNode(@[
      "persistence",
      "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
      "--circom-wasm=tests/circuits/fixtures/proof_main.wasm",
      "--circom-no-zkey"
    ])
    node.waitUntilOutput("Persistence enabled, but no Ethereum account was set")
    node.stop()

  test "complains when ethereum private key file has wrong permissions":
    let unsafeKeyFile = genTempPath("", "")
    discard unsafeKeyFile.writeFile(key, 0o666)
    let node = startNode(@[
      "persistence",
      "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
      "--circom-wasm=tests/circuits/fixtures/proof_main.wasm",
      "--circom-no-zkey",
      "--eth-private-key=" & unsafeKeyFile])
    node.waitUntilOutput("Ethereum private key file does not have safe file permissions")
    node.stop()
    discard removeFile(unsafeKeyFile)
