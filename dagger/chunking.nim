import ./merkledag

export merkledag

proc createChunks*(file: File): MerkleDag =
  let contents = file.readAll()
  MerkleDag(data: cast[seq[byte]](contents))

proc assembleChunks*(dag: MerkleDag, output: File) =
  output.write(cast[string](dag.data))
