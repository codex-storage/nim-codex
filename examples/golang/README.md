
## Pre-requisite

libstorage.so is needed to be compiled and present in build folder.

## Compilation

From the Logos Storage root folder:

```code
go build -o storage-go examples/golang/storage.go
```

## Run
From the storage root folder:


```code
export LD_LIBRARY_PATH=build
```

```code
./storage-go
```
