import ./merkletree/merkletree
import ./merkletree/codex
import ./merkletree/poseidon2

export codex, poseidon2, merkletree

type
  SomeMerkleTree* = ByteTree | CodexTree | Poseidon2Tree
  SomeMerkleProof* = ByteProof | CodexProof | Poseidon2Proof
  SomeMerkleHash* = ByteHash | Poseidon2Hash
