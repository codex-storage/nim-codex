import ./obj

export obj

proc createObject*(file: File): Object =
  let contents = file.readAll()
  Object(data: cast[seq[byte]](contents))

proc writeToFile*(obj: Object, output: File) =
  output.write(cast[string](obj.data))
