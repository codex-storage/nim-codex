const header = "leopard.h"

{.pragma: leo, cdecl, header: header, importCpp.}

proc leo_init*(): cint {.leo.}
