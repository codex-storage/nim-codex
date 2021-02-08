import ./ipfsobject

export ipfsobject

proc createObject*(file: File): IpfsObject =
  let contents = file.readAll()
  IpfsObject(data: cast[seq[byte]](contents))

proc writeToFile*(obj: IpfsObject, output: File) =
  if obj.data.len > 0:
    discard output.writeBuffer(unsafeAddr obj.data[0], obj.data.len)
