import ./ipfsobject

export ipfsobject

proc createObject*(file: File): IpfsObject =
  let contents = file.readAll()
  IpfsObject(data: cast[seq[byte]](contents))

proc writeToFile*(obj: IpfsObject, output: File) =
  output.write(cast[string](obj.data))
