import std/hashes
import pkg/contractabi
import pkg/nimcrypto
import pkg/ethers/fields
import pkg/questionable/results

export contractabi

type
  MarketplaceConfig* = object
    collateral*: CollateralConfig
    proofs*: ProofConfig
  CollateralConfig* = object
    initialAmount*: UInt256 # amount of collateral necessary to fill a slot
    minimumAmount*: UInt256 # frees slot when collateral drops below this minimum
    slashCriterion*: UInt256 # amount of proofs missed that lead to slashing
    slashPercentage*: UInt256 # percentage of the collateral that is slashed
  ProofConfig* = object
    period*: UInt256 # proofs requirements are calculated per period (in seconds)
    timeout*: UInt256 # mark proofs as missing before the timeout (in seconds)
    downtime*: uint8 # ignore this much recent blocks for proof requirements


func fromTuple(_: type ProofConfig, tupl: tuple): ProofConfig =
  ProofConfig(
    period: tupl[0],
    timeout: tupl[1],
    downtime: tupl[2]
  )

func fromTuple(_: type CollateralConfig, tupl: tuple): CollateralConfig =
  CollateralConfig(
    initialAmount: tupl[0],
    minimumAmount: tupl[1],
    slashCriterion: tupl[2],
    slashPercentage: tupl[3]
  )

func fromTuple(_: type MarketplaceConfig, tupl: tuple): MarketplaceConfig =
  MarketplaceConfig(
    collateral: tupl[0],
    proofs: tupl[1]
  )

func solidityType*(_: type ProofConfig): string =
  solidityType(ProofConfig.fieldTypes)

func solidityType*(_: type CollateralConfig): string =
  solidityType(CollateralConfig.fieldTypes)

func solidityType*(_: type MarketplaceConfig): string =
  solidityType(CollateralConfig.fieldTypes)

func encode*(encoder: var AbiEncoder, slot: ProofConfig) =
  encoder.write(slot.fieldValues)

func encode*(encoder: var AbiEncoder, slot: CollateralConfig) =
  encoder.write(slot.fieldValues)

func encode*(encoder: var AbiEncoder, slot: MarketplaceConfig) =
  encoder.write(slot.fieldValues)

func decode*(decoder: var AbiDecoder, T: type ProofConfig): ?!T =
  let tupl = ?decoder.read(ProofConfig.fieldTypes)
  success ProofConfig.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type CollateralConfig): ?!T =
  let tupl = ?decoder.read(CollateralConfig.fieldTypes)
  success CollateralConfig.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type MarketplaceConfig): ?!T =
  let tupl = ?decoder.read(MarketplaceConfig.fieldTypes)
  success MarketplaceConfig.fromTuple(tupl)
