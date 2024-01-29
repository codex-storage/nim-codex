import ./merkletree/merkletree
import ./merkletree/codex
import ./merkletree/poseidon2

export codex, poseidon2, merkletree

type
  AnyMerkleTree* = ByteTree | CodexTree | Poseidon2Tree
  AnyMerkleProof* = ByteProof | CodexProof | Poseidon2Proof
  AnyMerkleHash* = ByteHash | Poseidon2Hash
