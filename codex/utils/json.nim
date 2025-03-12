import std/options
import std/typetraits
from pkg/ethers import Address
from pkg/libp2p import
  Cid, PeerId, SignedPeerRecord, MultiAddress, AddressInfo, MultiHash, init, hex, `$`
import pkg/stew/byteutils
import pkg/contractabi
import pkg/codexdht/discv5/node as dn
import pkg/serde/json
import pkg/questionable/results
import ../errors

export json

proc fromJson*(_: type Cid, json: JsonNode): ?!Cid =
  expectJsonKind(Cid, JString, json)
  Cid.init(json.str).mapFailure

func `%`*(cid: Cid): JsonNode =
  % $cid

func `%`*(obj: PeerId): JsonNode =
  % $obj

func `%`*(obj: SignedPeerRecord): JsonNode =
  % $obj

func `%`*(obj: dn.Address): JsonNode =
  % $obj

func `%`*(obj: AddressInfo): JsonNode =
  % $obj.address

func `%`*(obj: MultiAddress): JsonNode =
  % $obj

func `%`*(address: ethers.Address): JsonNode =
  % $address

proc fromJson*(_: type MultiHash, json: JsonNode): ?!MultiHash =
  expectJsonKind(MultiHash, JString, json)
  echo "[MultiHash.fromJson] json.str: ", json.str
  without bytes =? json.str.hexToSeqByte.catch, err:
    return failure(err.msg)
  MultiHash.init(bytes).mapFailure

func `%`*(multiHash: MultiHash): JsonNode =
  %multiHash.hex
