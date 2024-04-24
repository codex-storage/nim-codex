import std/hashes
import std/json
import std/strutils
import std/strformat
import std/os
import std/osproc

template withDir(dir: string, blk: untyped) =
  let prev = getCurrentDir()
  try:
    setCurrentDir(dir)
    `blk`
  finally:
    setCurrentDir(prev)

proc setProjDir(prev = getCurrentDir()): string =
  if not "codex.nimble".fileExists():
    setCurrentDir("..")
    if prev == getCurrentDir():
      echo "\nERROR: Codex project folder not found (could not find codex.nimble)"
      echo "\nBenchmark must be run from within the Codex project folder"
      quit 1
    setProjDir()
  else:
    getCurrentDir()

var
  nimCircuitCli =
    "vendor" / "codex-storage-proofs-circuits" / "reference" / "nim" / "proof_input" /
    "cli"
  circuitDirIncludes = "vendor" / "codex-storage-proofs-circuits" / "circuit"
  ptauDefPath = "benchmarks" / "ceremony" / "powersOfTau28_hez_final_21.ptau"
  ptauDefUrl =
    "https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_21.ptau"
  codexProjDir = ""

proc checkEnv*() =
  codexProjDir = setProjDir()
  echo "\n\nFound project dir: ", codexProjDir

  let snarkjs = findExe("snarkjs")
  if snarkjs == "":
    echo dedent"""
    ERROR: must install snarkjs first

      npm install -g snarkjs@latest
    """

  let circom = findExe("circom")
  if circom == "":
    echo dedent"""
    ERROR: must install circom first

      git clone https://github.com/iden3/circom.git
      cargo install --path circom
    """

  if snarkjs == "" or circom == "":
    quit 2

  echo "Found SnarkJS: ", snarkjs
  echo "Found Circom: ", circom

  if not nimCircuitCli.fileExists:
    echo "Nim Circuit reference cli not found: ", nimCircuitCli
    echo "Building Circuit reference cli...\n"
    withDir(nimCircuitCli.parentDir):
      discard execShellCmd("nimble build -d:release --styleCheck:off cli")
    echo "CWD: ", getCurrentDir()
    assert nimCircuitCli.fileExists()

  nimCircuitCli = nimCircuitCli.absolutePath()
  echo "Found NimCircuitCli: ", nimCircuitCli

  circuitDirIncludes = circuitDirIncludes.absolutePath
  echo "Found Circuit Path: ", circuitDirIncludes

  ptauDefPath = ptauDefPath.absolutePath
  echo "Found PTAU file: ", ptauDefPath

type CircArgs* = object
  depth*: int
  maxslots*: int
  cellsize*: int
  blocksize*: int
  nsamples*: int
  entropy*: int
  seed*: int
  nslots*: int
  ncells*: int
  index*: int

proc downloadPtau*(ptauPath, ptauUrl: string) =
  if not ptauPath.fileExists:
    echo "Ceremony file not found, downloading..."
    echo "PTAU url: ", ptauUrl
    createDir(ptauPath.parentDir)
    withDir(ptauPath.parentDir):
      discard execShellCmd(fmt"curl -LOC - {ptauDefUrl}")

proc getCircuitBenchPath*(args: CircArgs): string =
  absolutePath("benchmarks/circuit_bench_" & $cast[uint](hash(args)))

proc createCircuit*(
    args: CircArgs,
    name = "proof_main",
    circBenchDir = getCircuitBenchPath(args),
    circuitDirIncludes = circuitDirIncludes,
    ptauPath = ptauDefPath,
    ptauUrl = ptauDefUrl,
    someEntropy = "some_entropy_75289v3b7rcawcsyiur",
) =
  ## Generates all the files needed for to run a proof circuit. Downloads the PTAU file if needed.
  ## 
  let circdir = circBenchDir

  downloadPtau(ptauPath, ptauUrl)

  echo "Creating circuit dir: ", circdir
  createDir(circdir)
  withDir circdir:
    writeFile("circuit_params.json", pretty(%*args))
    let
      zkey = circdir / fmt"{name}.zkey"
      wasm = circdir / fmt"{name}.wasm"
      r1cs = circdir / fmt"{name}.r1cs"

    var cliCmd = nimCircuitCli
    for f, v in fieldPairs(args):
      cliCmd &= " --" & f & "=" & $v

    if not "input.json".fileExists:
      echo "Generating Circom Files..."
      # ${NIMCLI_DIR}/cli $CLI_ARGS -v --circom=${CIRCUIT_MAIN}.circom --output=input.json
      cliCmd &= fmt" -v --circom={name}.circom --output=input.json"
      echo "CWD: ", getCurrentDir()
      echo "CLI_CMD: ", cliCmd

      let cliRes = execShellCmd(cliCmd)
      echo "RES: ", cliRes
      assert cliRes == 0

    if not wasm.fileExists or not r1cs.fileExists:
      let cmd = fmt"circom --r1cs --wasm --O2 -l{circuitDirIncludes} {name}.circom"
      echo "CMD: ", cmd
      let cmdRes = execShellCmd(cmd)
      echo "RES: ", cmdRes
      assert cmdRes == 0
      moveFile(fmt"{name}_js" / fmt"{name}.wasm", fmt"{name}.wasm")
    echo "Found wasm: ", wasm
    echo "Found r1cs: ", r1cs

    if not zkey.fileExists:
      echo "Zkey not found, generating..."
      putEnv("NODE_OPTIONS", "--max-old-space-size=8192")
      discard execShellCmd("echo $NODE_OPTIONS")
      if not fmt"{name}_0000.zkey".fileExists:
        let cmd = fmt"snarkjs groth16 setup {r1cs} {ptauPath} {name}_0000.zkey"
        echo "CMD: ", cmd
        let cmdRes = execShellCmd(cmd)
        assert cmdRes == 0
        echo fmt"Generated {name}_0000.zkey"

      let cmd =
        fmt"snarkjs zkey contribute {name}_0000.zkey {name}_0001.zkey --name='1st Contributor Name'"
      echo "CMD: ", cmd
      let cmdRes = execCmdEx(cmd, options = {}, input = someEntropy & "\n")
      assert cmdRes.exitCode == 0

      moveFile(fmt"{name}_0001.zkey", fmt"{name}.zkey")
      removeFile(fmt"{name}_0000.zkey")

when isMainModule:
  checkEnv()

  let args = CircArgs(
    depth: 32, # maximum depth of the slot tree 
    maxslots: 256, # maximum number of slots  
    cellsize: 2048, # cell size in bytes 
    blocksize: 65536, # block size in bytes 
    nsamples: 5, # number of samples to prove
    entropy: 1234567, # external randomness
    seed: 12345, # seed for creating fake data
    nslots: 11, # number of slots in the dataset
    index: 3, # which slot we prove (0..NSLOTS-1)
    ncells: 512, # number of cells in this slot
  )
  createCircuit(args)
