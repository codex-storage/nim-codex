
## Pre-requisite

libcodex.so is needed to be compiled and present in build folder.

## Compilation

From the codex root folder:

```code
go build -o codex-go examples/golang/codex.go
```

## Run
From the codex root folder:


```code
export LD_LIBRARY_PATH=build
```

```code
./codex-go
```
