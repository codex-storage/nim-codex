import options
import leveldb

when isMainModule:
  let db = leveldb.open("/tmp/testleveldb/tooldb")
  db.put("hello", "world")
  let val = db.get("hello")
  if val.isSome() and val.get() == "world":
    echo "leveldb works."
  db.close()
