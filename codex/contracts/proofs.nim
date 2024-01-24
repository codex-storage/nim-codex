import pkg/stint
import pkg/contractabi
import pkg/ethers/fields

type
  Groth16Proof* = object
    a*: G1Point
    b*: G2Point
    c*: G1Point
  G1Point* = object
    x*: UInt256
    y*: UInt256
  G2Point* = object
    x*: array[2, UInt256]
    y*: array[2, UInt256]

func solidityType*(_: type G1Point): string =
  solidityType(G1Point.fieldTypes)

func solidityType*(_: type G2Point): string =
  solidityType(G2Point.fieldTypes)

func solidityType*(_: type Groth16Proof): string =
  solidityType(Groth16Proof.fieldTypes)

func encode*(encoder: var AbiEncoder, point: G1Point) =
  encoder.write(point.fieldValues)

func encode*(encoder: var AbiEncoder, point: G2Point) =
  encoder.write(point.fieldValues)

func encode*(encoder: var AbiEncoder, proof: Groth16Proof) =
  encoder.write(proof.fieldValues)
