import std/[sequtils, strformat, os, options, importutils]
import std/[times, os, strutils, terminal]

import pkg/questionable
import pkg/questionable/results
import pkg/datastore

import pkg/codex/[rng, stores, merkletree, codextypes, slots]
import pkg/codex/utils/[json, poseidon2digest]
import pkg/codex/slots/[builder, sampler/utils, backends/helpers]
import pkg/constantine/math/[arithmetic, io/io_bigints, io/io_fields]

import ./utils
import ./create_circuits

type CircuitFiles* = object
  r1cs*: string
  wasm*: string
  zkey*: string
  inputs*: string

proc runArkCircom(args: CircuitArgs, files: CircuitFiles) =
  echo "Loading sample proof..."
  var
    proofInputs = Poseidon2Hash.jsonToProofInput(inputJson)
    circom = CircomCompat.init(
      files.r1cs,
      files.wasm,
      files.zkey,
      slotDepth = args.depth,
      numSamples = args.nsamples,
      # slotDepth     : int     # max depth of the slot tree
      # datasetDepth  : int     # max depth of dataset  tree
      # blkDepth      : int     # depth of the block merkle tree (pow2 for now)
      # cellElms      : int     # number of field elements per cell
      # numSamples    : int     # number of samples per slot
    )
  defer:
    circom.release() # this comes from the rust FFI

  echo "Sample proof loaded..."
  echo "Proving..."

  var proof: CircomProof
  benchmark fmt"prover":
    proof = circom.prove(proofInputs).tryGet

  var verRes: bool
  benchmark fmt"verify":
    verRes = circom.verify(proof, proofInputs).tryGet
  echo "verify result: ", verRes

proc printHelp() =
  echo "usage:"
  echo "  ./codex_ark_prover_cli [options] --output=proof_input.json --circom=proof_main.circom"
  echo ""
  echo "available options:"
  echo " -h, --help                         : print this help"
  echo " -v, --verbose                      : verbose output (print the actual parameters)"
  echo " -d, --depth      = <maxdepth>      : maximum depth of the slot tree (eg. 32)"
  echo " -N, --maxslots   = <maxslots>      : maximum number of slots (eg. 256)"
  echo " -c, --cellsize   = <cellSize>      : cell size in bytes (eg. 2048)"
  echo " -b, --blocksize  = <blockSize>     : block size in bytes (eg. 65536)"
  echo " -s, --nslots     = <nslots>        : number of slots in the dataset (eg. 13)"
  echo " -n, --nsamples   = <nsamples>      : number of samples we prove (eg. 100)"
  echo " -e, --entropy    = <entropy>       : external randomness (eg. 1234567)"
  echo " -S, --seed       = <seed>          : seed to generate the fake data (eg. 12345)"
  echo " -f, --file       = <datafile>      : slot data file, base name (eg. \"slotdata\" would mean \"slotdata5.dat\" for slot index = 5)"
  echo " -i, --index      = <slotIndex>     : index of the slot (within the dataset) we prove"
  echo " -k, --log2ncells = <log2(ncells)>  : log2 of the number of cells inside this slot (eg. 10)"
  echo " -K, --ncells     = <ncells>        : number of cells inside this slot (eg. 1024; must be a power of two)"
  echo " -o, --output     = <input.json>    : the JSON file into which we write the proof input"
  echo " -C, --circom     = <main.circom>   : the circom main component to create with these parameters"
  echo ""

  quit()

#-------------------------------------------------------------------------------

proc parseCliOptions(): FullConfig =

  var argCtr: int = 0

  var globCfg = defGlobCfg
  var dsetCfg = defDSetCfg
  var fullCfg = defFullCfg

  for kind, key, value in getOpt():
    case kind

    # Positional arguments
    of cmdArgument:
      # echo ("arg #" & $argCtr & " = " & key)
      argCtr += 1

    # Switches
    of cmdLongOption, cmdShortOption:
      case key

      of "h", "help"      : printHelp()
      of "v", "verbose"   : fullCfg.verbose       = true
      of "d", "depth"     : globCfg.maxDepth      = parseInt(value) 
      of "N", "maxslots"  : globCfg.maxLog2NSlots = ceilingLog2(parseInt(value))
      of "c", "cellsize"  : globCfg.cellSize      = checkPowerOfTwo(parseInt(value),"cellSize")
      of "b", "blocksize" : globCfg.blockSize     = checkPowerOfTwo(parseInt(value),"blockSize")
      of "s", "nslots"    : dsetCfg.nSlots        = parseInt(value)
      of "n", "nsamples"  : dsetCfg.nsamples      = parseInt(value)
      of "e", "entropy"   : fullCfg.entropy       = parseInt(value)
      of "S", "seed"      : dsetCfg.dataSrc       = DataSource(kind: FakeData, seed: uint64(parseInt(value)))
      of "f", "file"      : dsetCfg.dataSrc       = DataSource(kind: SlotFile, filename: value)
      of "i", "index"     : fullCfg.slotIndex     = parseInt(value)
      of "k", "log2ncells": dsetCfg.ncells        = pow2(parseInt(value))
      of "K", "ncells"    : dsetCfg.ncells        = checkPowerOfTwo(parseInt(value),"nCells")
      of "o", "output"    : fullCfg.outFile       = value
      of "C", "circom"    : fullCfg.circomFile    = value
      else:
        echo "Unknown option: ", key
        echo "use --help to get a list of options"
        quit()

    of cmdEnd:
      discard  

  fullCfg.globCfg = globCfg
  fullCfg.dsetCfg = dsetCfg

  return fullCfg


proc run*() =
  echo "Running benchmark"
  # setup()

  var
    inputData = inputJson.readFile()
    inputs = !JsonNode.parse(inputData)

  # Proving defaults
  echo DefaultMaxSlotDepth
  echo DefaultMaxDatasetDepth
  echo DefaultBlockDepth
  echo DefaultCellElms
  
  # prove wasm ${CIRCUIT_MAIN}.zkey witness.wtns proof.json public.json

  var args = CircuitArgs(
    depth: DefaultMaxSlotDepth, # maximum depth of the slot tree
    maxslots: 256, # maximum number of slots
    cellsize: DefaultCellSize, # cell size in bytes
    blocksize: DefaultBlockSize, # block size in bytes
    nsamples: 1, # number of samples to prove
    entropy: 1234567, # external randomness
    seed: 12345, # seed for creating fake data
    nslots: inputs.nSlotsPerDataSet, # number of slots in the dataset
    index: inputs.slotIndex, # which slot we prove (0..NSLOTS-1)
    ncells: inputs.nCellsPerSlot, # number of cells in this slot
  )

  ## TODO: copy over testcircomcompat proving
  let files = CircuitFiles(
    r1cs: dir / fmt"{env.name}.r1cs",
    wasm: dir / fmt"{env.name}.wasm",
    zkey: dir / fmt"{env.name}.zkey",
    inputs: dir / fmt"input.json",
  )

  runArkCircom(args, files)

when isMainModule:
  run()
