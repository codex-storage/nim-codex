import std/sequtils
import std/strutils
import std/strformat
import std/os
import std/options
import std/importutils
import std/[times, os, strutils]
import std/terminal


import pkg/questionable
import pkg/questionable/results
import pkg/datastore

import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/merkletree
import pkg/codex/utils/json
import pkg/codex/codextypes
import pkg/codex/slots
import pkg/codex/slots/builder
import pkg/codex/utils/poseidon2digest
import pkg/codex/slots/sampler/utils

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints
import pkg/constantine/math/io/io_fields

import codex/slots/backends/helpers

import create_circuits

template benchmark(benchmarkName: string, blk: untyped) =
  let nn = 5
  var vals = newSeqOfCap[float](nn)
  for i in 1..nn:
    block:
      let t0 = epochTime()
      # `blk`
      let elapsed = epochTime() - t0
      vals.add elapsed
  
  var elapsedStr = ""
  for v in vals:
    elapsedStr &= ", " & v.formatFloat(format = ffDecimal, precision = 3)
  stdout.styledWriteLine(fgGreen, "CPU Time [", benchmarkName, "] ", "avg(", $nn, "): ", elapsedStr, " s")

proc setup(
  circuitDir: string, name: string,
) =
  let
    inputData = readFile("tests/circuits/fixtures/input.json")
    inputJson: JsonNode = !JsonNode.parse(inputData)
    proofInput: ProofInputs[Poseidon2Hash] = Poseidon2Hash.jsonToProofInput(inputJson)

  let datasetProof = Poseidon2Proof.init(
    proofInput.slotIndex, proofInput.nSlotsPerDataSet, proofInput.slotProof[0 ..< 4]
  ).tryGet

  let ver = datasetProof.verify(proofInput.slotRoot, proofInput.datasetRoot).tryGet
  echo "ver: ", ver

proc runBenchmark(args: CircArgs) =

  let env = createCircuit(args)

  ## TODO: copy over testcircomcompat proving
  let
    r1cs = env.dir / fmt"{env.name}.r1cs"
    wasm = env.dir / fmt"{env.name}.wasm"
    zkey = env.dir / fmt"{env.name}.zkey"
    inputs = env.dir / fmt"input.json"

  echo "Loading sample proof..."
  var
    inputData = inputs.readFile()
    inputJson = !JsonNode.parse(inputData)
    proofInputs = Poseidon2Hash.jsonToProofInput(inputJson)
    circom = CircomCompat.init(
      r1cs,
      wasm,
      zkey,
      slotDepth = args.depth,
      numSamples = args.nsamples,
    )
  defer:
    circom.release()  # this comes from the rust FFI

  echo "Sample proof loaded..."
  echo "Proving..."

  var proof: CircomProof
  benchmark fmt"prover":
    proof = circom.prove(proofInputs).tryGet

  var verRes: bool
  benchmark fmt"verify":
    verRes = circom.verify(proof, proofInputs).tryGet
  echo "verify result: ", verRes

  when false:
    proofInputs.slotIndex = 1 # change slot index

    let proof = circom.prove(proofInputs).tryGet
    echo "verify bad result: ", circom.verify(proof, proofInputs).tryGet


when isMainModule:
  echo "Running benchmark"
  # setup()
  checkEnv()
  var args = CircArgs(
    depth: 32, # maximum depth of the slot tree 
    maxslots: 256, # maximum number of slots  
    cellsize: 2048, # cell size in bytes 
    blocksize: 65536, # block size in bytes 
    nsamples: 1, # number of samples to prove
    entropy: 1234567, # external randomness
    seed: 12345, # seed for creating fake data
    nslots: 11, # number of slots in the dataset
    index: 3, # which slot we prove (0..NSLOTS-1)
    ncells: 512, # number of cells in this slot
  )

  for i in 1..9:
    args.nsamples = i
    stdout.styledWriteLine(fgYellow, "\nbenchmarking args: ", $args)
    args.runBenchmark()

  for i in 1..16:
    args.nsamples = 10*i
    stdout.styledWriteLine(fgYellow, "\nbenchmarking args: ", $args)
    args.runBenchmark()
