proc alloc*(str: cstring): cstring =
  # Byte allocation from the given address.
  # There should be the corresponding manual deallocation with deallocShared !
  if str.isNil():
    var ret = cast[cstring](allocShared(1)) # Allocate memory for the null terminator
    ret[0] = '\0' # Set the null terminator
    return ret

  let ret = cast[cstring](allocShared(len(str) + 1))
  copyMem(ret, str, len(str) + 1)
  return ret

proc alloc*(str: string): cstring =
  ## Byte allocation from the given address.
  ## There should be the corresponding manual deallocation with deallocShared !
  var ret = cast[cstring](allocShared(str.len + 1))
  let s = cast[seq[char]](str)
  for i in 0 ..< str.len:
    ret[i] = s[i]
  ret[str.len] = '\0'
  return ret
