# Package

version       = "0.4.1"
author        = "Michał Zieliński"
description   = "LevelDB wrapper for Nim"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["leveldbtool"]

# Dependencies

requires "nim >= 1.4.0"
