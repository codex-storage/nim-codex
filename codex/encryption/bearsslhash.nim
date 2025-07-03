import bearssl/hash

proc bearSslHash*(hashClass: ptr HashClass, data: openArray[byte]): seq[byte] =
  var compatCtx = HashCompatContext()
  let buffSize = (hashClass[].desc shr HASHDESC_OUT_OFF) and HASHDESC_OUT_MASK
  result = newSeq[byte](buffSize)

  let hashClassPtrPtr: ConstPtrPtrHashClass = addr(compatCtx.vtable)

  hashClass[].init(hashClassPtrPtr)
  hashClass[].update(hashClassPtrPtr, addr data[0], data.len.uint)
  hashClass[].`out`(hashClassPtrPtr, addr result[0])
