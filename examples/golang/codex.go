package main

/*
   	#cgo LDFLAGS: -L../../build/ -lcodex
	#cgo LDFLAGS: -L../../ -Wl,-rpath,../../

	#include <stdbool.h>
   	#include <stdlib.h>
   	#include "../../library/libcodex.h"

   	typedef struct {
       int ret;
       char* msg;
       size_t len;
       uintptr_t h;
   	} Resp;

   	static void* allocResp(uintptr_t h) {
       Resp* r = (Resp*)calloc(1, sizeof(Resp));
       r->h = h;
       return r;
   	}

   	static void freeResp(void* resp) {
       if (resp != NULL) {
           free(resp);
       }
   	}

   	static int getRet(void* resp) {
       if (resp == NULL) {
           return 0;
       }
       Resp* m = (Resp*) resp;
       return m->ret;
   	}

   void libcodexNimMain(void);

   static void codex_host_init_once(void){
       static int done;
       if (!__atomic_exchange_n(&done, 1, __ATOMIC_SEQ_CST)) libcodexNimMain();
   }

   // resp must be set != NULL in case interest on retrieving data from the callback
   void callback(int ret, char* msg, size_t len, void* resp);

   static void* cGoCodexNew(const char* configJson, void* resp) {
       void* ret = codex_new(configJson, (CodexCallback) callback, resp);
       return ret;
   }

   static int cGoCodexStart(void* codexCtx, void* resp) {
       return codex_start(codexCtx, (CodexCallback) callback, resp);
   }

   static int cGoCodexStop(void* codexCtx, void* resp) {
       return codex_stop(codexCtx, (CodexCallback) callback, resp);
   }

	static int cGoCodexClose(void* codexCtx, void* resp) {
		return codex_close(codexCtx, (CodexCallback) callback, resp);
	}

   static int cGoCodexDestroy(void* codexCtx, void* resp) {
       return codex_destroy(codexCtx, (CodexCallback) callback, resp);
   }

    static int cGoCodexVersion(void* codexCtx, void* resp) {
       return codex_version(codexCtx, (CodexCallback) callback, resp);
   }

   static int cGoCodexRevision(void* codexCtx, void* resp) {
       return codex_revision(codexCtx, (CodexCallback) callback, resp);
   }

   static int cGoCodexRepo(void* codexCtx, void* resp) {
       return codex_repo(codexCtx, (CodexCallback) callback, resp);
   }

   static int cGoCodexSpr(void* codexCtx, void* resp) {
       return codex_spr(codexCtx, (CodexCallback) callback, resp);
   }

   static int cGoCodexPeerId(void* codexCtx, void* resp) {
       return codex_peer_id(codexCtx, (CodexCallback) callback, resp);
   }

   static int cGoCodexUploadInit(void* codexCtx, char* filepath, size_t chunkSize, void* resp) {
      return codex_upload_init(codexCtx, filepath, chunkSize, (CodexCallback) callback, resp);
   }

   static int cGoCodexUploadChunk(void* codexCtx, char* sessionId, const uint8_t* chunk, size_t len, void* resp) {
      return codex_upload_chunk(codexCtx, sessionId, chunk, len, (CodexCallback) callback, resp);
   }

   static int cGoCodexUploadFinalize(void* codexCtx, char* sessionId, void* resp) {
      return codex_upload_finalize(codexCtx, sessionId, (CodexCallback) callback, resp);
   }

   static int cGoCodexUploadCancel(void* codexCtx, char* sessionId, void* resp) {
      return codex_upload_cancel(codexCtx, sessionId, (CodexCallback) callback, resp);
   }

   static int cGoCodexUploadFile(void* codexCtx, char* sessionId, void* resp) {
      return codex_upload_file(codexCtx, sessionId, (CodexCallback) callback, resp);
   }

   static int cGoCodexLogLevel(void* codexCtx, char* logLevel, void* resp) {
       return codex_log_level(codexCtx, logLevel, (CodexCallback) callback, resp);
   }

   static int cGoCodexExists(void* codexCtx, char* cid, void* resp) {
      return codex_storage_exists(codexCtx, cid, (CodexCallback) callback, resp);
   }
*/
import "C"
import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"runtime/cgo"
	"sync"
	"syscall"
	"unsafe"
)

type LogFormat string

const (
	LogFormatAuto     LogFormat = "auto"
	LogFormatColors   LogFormat = "colors"
	LogFormatNoColors LogFormat = "nocolors"
	LogFormatJSON     LogFormat = "json"
)

type RepoKind string

const (
	FS      RepoKind = "fs"
	SQLite  RepoKind = "sqlite"
	LevelDb RepoKind = "leveldb"
)

const defaultBlockSize = 1024 * 64

type Config struct {
	// Default: INFO
	LogLevel string `json:"log-level,omitempty"`

	// Specifies what kind of logs should be written to stdout
	// Default: auto
	LogFormat LogFormat `json:"log-format,omitempty"`

	// Enable the metrics server
	// Default: false
	MetricsEnabled bool `json:"metrics,omitempty"`

	// Listening address of the metrics server
	// Default: 127.0.0.1
	MetricsAddress string `json:"metrics-address,omitempty"`

	// Listening HTTP port of the metrics server
	// Default: 8008
	MetricsPort int `json:"metrics-port,omitempty"`

	// The directory where codex will store configuration and data
	// Default:
	// $HOME\AppData\Roaming\Codex on Windows
	// $HOME/Library/Application Support/Codex on macOS
	// $HOME/.cache/codex on Linux
	DataDir string `json:"data-dir,omitempty"`

	// Multi Addresses to listen on
	// Default: ["/ip4/0.0.0.0/tcp/0"]
	ListenAddrs []string `json:"listen-addrs,omitempty"`

	// Specify method to use for determining public address.
	// Must be one of: any, none, upnp, pmp, extip:<IP>
	// Default: any
	Nat string `json:"nat,omitempty"`

	// Discovery (UDP) port
	// Default: 8090
	DiscoveryPort int `json:"disc-port,omitempty"`

	// Source of network (secp256k1) private key file path or name
	// Default: "key"
	NetPrivKeyFile string `json:"net-privkey,omitempty"`

	// Specifies one or more bootstrap nodes to use when connecting to the network.
	BootstrapNodes []string `json:"bootstrap-node,omitempty"`

	// The maximum number of peers to connect to.
	// Default: 160
	MaxPeers int `json:"max-peers,omitempty"`

	// Number of worker threads (\"0\" = use as many threads as there are CPU cores available)
	// Default: 0
	NumThreads int `json:"num-threads,omitempty"`

	// Node agent string which is used as identifier in network
	// Default: "Codex"
	AgentString string `json:"agent-string,omitempty"`

	// Backend for main repo store (fs, sqlite, leveldb)
	// Default: fs
	RepoKind RepoKind `json:"repo-kind,omitempty"`

	// The size of the total storage quota dedicated to the node
	// Default: 20 GiBs
	StorageQuota int `json:"storage-quota,omitempty"`

	// Default block timeout in seconds - 0 disables the ttl
	// Default: 30 days
	BlockTtl int `json:"block-ttl,omitempty"`

	// Time interval in seconds - determines frequency of block
	// maintenance cycle: how often blocks are checked for expiration and cleanup
	// Default: 10 minutes
	BlockMaintenanceInterval int `json:"block-mi,omitempty"`

	// Number of blocks to check every maintenance cycle
	// Default: 1000
	BlockMaintenanceNumberOfBlocks int `json:"block-mn,omitempty"`

	// Number of times to retry fetching a block before giving up
	// Default: 3000
	BlockRetries int `json:"block-retries,omitempty"`

	// The size of the block cache, 0 disables the cache -
	// might help on slow hardrives
	// Default: 0
	CacheSize int `json:"cache-size,omitempty"`

	// Default: "" (no log file)
	LogFile string `json:"log-file,omitempty"`
}

type CodexNode struct {
	ctx unsafe.Pointer
}

type ChunkSize int

func (c ChunkSize) valOrDefault() int {
	if c == 0 {
		return defaultBlockSize
	}

	return int(c)
}

func (c ChunkSize) toSizeT() C.size_t {
	return C.size_t(c.valOrDefault())
}

// bridgeCtx is used for managing the C-Go bridge calls.
// It contains a wait group for synchronizing the calls,
// a cgo.Handle for passing context to the C code,
// a response pointer for receiving data from the C code,
// and fields for storing the result and error of the call.
type bridgeCtx struct {
	wg     *sync.WaitGroup
	h      cgo.Handle
	resp   unsafe.Pointer
	result string
	err    error

	// Callback used for receiving progress updates during upload/download.
	//
	// For the upload, the bytes parameter indicates the number of bytes uploaded.
	// If the chunk size is superior or equal to the blocksize (passed in init function),
	// the callback will be called when a block is put in the store.
	// Otherwise, it will be called when a chunk is pushed into the stream.
	//
	// For the download, the bytes is the size of the chunk received, and the chunk
	// is the actual chunk of data received.
	onProgress func(bytes int, chunk []byte)
}

// newBridgeCtx creates a new bridge context for managing C-Go calls.
// The bridge context is initialized with a wait group and a cgo.Handle.
func newBridgeCtx() *bridgeCtx {
	bridge := &bridgeCtx{}
	bridge.wg = &sync.WaitGroup{}
	bridge.wg.Add(1)
	bridge.h = cgo.NewHandle(bridge)
	bridge.resp = C.allocResp(C.uintptr_t(uintptr(bridge.h)))
	return bridge
}

// callError creates an error message for a failed C-Go call.
func (b *bridgeCtx) callError(name string) error {
	return fmt.Errorf("failed the call to %s returned code %d", name, C.getRet(b.resp))
}

// free releases the resources associated with the bridge context,
// including the cgo.Handle and the response pointer.
func (b *bridgeCtx) free() {
	if b.h > 0 {
		b.h.Delete()
		b.h = 0
	}

	if b.resp != nil {
		C.freeResp(b.resp)
		b.resp = nil
	}
}

// callback is the function called by the C code to communicate back to Go.
// It handles progress updates, successful completions, and errors.
// The function uses the response pointer to retrieve the bridge context
// and update its state accordingly.
//
//export callback
func callback(ret C.int, msg *C.char, len C.size_t, resp unsafe.Pointer) {
	if resp == nil {
		return
	}

	m := (*C.Resp)(resp)
	m.ret = ret
	m.msg = msg
	m.len = len

	if m.h == 0 {
		return
	}

	h := cgo.Handle(m.h)
	if h == 0 {
		return
	}

	if v, ok := h.Value().(*bridgeCtx); ok {
		switch ret {
		case C.RET_PROGRESS:
			if v.onProgress == nil {
				return
			}
			if msg != nil {
				chunk := C.GoBytes(unsafe.Pointer(msg), C.int(len))
				v.onProgress(int(C.int(len)), chunk)
			} else {
				v.onProgress(int(C.int(len)), nil)
			}
		case C.RET_OK:
			retMsg := C.GoStringN(msg, C.int(len))
			v.result = retMsg
			v.err = nil
			if v.wg != nil {
				v.wg.Done()
			}
		case C.RET_ERR:
			retMsg := C.GoStringN(msg, C.int(len))
			v.err = errors.New(retMsg)
			if v.wg != nil {
				v.wg.Done()
			}
		}
	}
}

// wait waits for the bridge context to complete its operation.
// It returns the result and error of the operation.
func (b *bridgeCtx) wait() (string, error) {
	b.wg.Wait()
	return b.result, b.err
}

type OnUploadProgressFunc func(read, total int, percent float64, err error)

type UploadOptions struct {
	// Filepath can be the full path when using UploadFile
	// otherwise the file name.
	// It is used to detect the mimetype.
	Filepath string

	// ChunkSize is the size of each upload chunk, passed as `blockSize` to the Codex node
	// store. Default is to 64 KB.
	ChunkSize ChunkSize

	// OnProgress is a callback function that is called after each chunk is uploaded with:
	//   - read: the number of bytes read in the last chunk.
	//   - total: the total number of bytes read so far.
	//   - percent: the percentage of the total file size that has been uploaded. It is
	//     determined from a `stat` call if it is a file and from the length of the buffer
	// 	   if it is a buffer. Otherwise, it is 0.
	//   - err: an error, if one occurred.
	//
	// If the chunk size is more than the `chunkSize` parameter, the callback is called
	// after the block is actually stored in the block store. Otherwise, it is called
	// after the chunk is sent to the stream.
	OnProgress OnUploadProgressFunc
}

func getReaderSize(r io.Reader) int64 {
	switch v := r.(type) {
	case *os.File:
		stat, err := v.Stat()
		if err != nil {
			return 0
		}
		return stat.Size()
	case *bytes.Buffer:
		return int64(v.Len())
	default:
		return 0
	}
}

// New creates a new Codex node with the provided configuration.
// The node is not started automatically; you need to call CodexStart
// to start it.
// It returns a Codex node that can be used to interact
// with the Codex network.
func New(config Config) (*CodexNode, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	jsonConfig, err := json.Marshal(config)
	if err != nil {
		return nil, err
	}

	cJsonConfig := C.CString(string(jsonConfig))
	defer C.free(unsafe.Pointer(cJsonConfig))

	ctx := C.cGoCodexNew(cJsonConfig, bridge.resp)

	if _, err := bridge.wait(); err != nil {
		return nil, bridge.err
	}

	return &CodexNode{ctx: ctx}, bridge.err
}

// Start starts the Codex node.
func (node CodexNode) Start() error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexStart(node.ctx, bridge.resp) != C.RET_OK {
		return bridge.callError("cGoCodexStart")
	}

	_, err := bridge.wait()
	return err
}

// StartAsync is the asynchronous version of Start.
func (node CodexNode) StartAsync(onDone func(error)) {
	go func() {
		err := node.Start()
		onDone(err)
	}()
}

// Stop stops the Codex node.
func (node CodexNode) Stop() error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexStop(node.ctx, bridge.resp) != C.RET_OK {
		return bridge.callError("cGoCodexStop")
	}

	_, err := bridge.wait()
	return err
}

// Destroy destroys the Codex node, freeing all resources.
// The node must be stopped before calling this method.
func (node CodexNode) Destroy() error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexClose(node.ctx, bridge.resp) != C.RET_OK {
		return bridge.callError("cGoCodexClose")
	}

	_, err := bridge.wait()
	if err != nil {
		return err
	}

	if C.cGoCodexDestroy(node.ctx, bridge.resp) != C.RET_OK {
		return errors.New("Failed to destroy the codex node.")
	}

	return err
}

// Version returns the version of the Codex node.
func (node CodexNode) Version() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexVersion(node.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.callError("cGoCodexVersion")
	}

	return bridge.wait()
}

func (node CodexNode) Revision() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexRevision(node.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.callError("cGoCodexRevision")
	}

	return bridge.wait()
}

// Repo returns the path of the data dir folder.
func (node CodexNode) Repo() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexRepo(node.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.callError("cGoCodexRepo")
	}

	return bridge.wait()
}

func (node CodexNode) Spr() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexSpr(node.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.callError("cGoCodexSpr")
	}

	return bridge.wait()
}

func (node CodexNode) PeerId() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexPeerId(node.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.callError("cGoCodexPeerId")
	}

	return bridge.wait()
}

// UploadInit initializes a new upload session.
// It returns a session ID that can be used for subsequent upload operations.
// This function is called by UploadReader and UploadFile internally.
// You should use this function only if you need to manage the upload session manually.
func (node CodexNode) UploadInit(options *UploadOptions) (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cFilename = C.CString(options.Filepath)
	defer C.free(unsafe.Pointer(cFilename))

	if C.cGoCodexUploadInit(node.ctx, cFilename, options.ChunkSize.toSizeT(), bridge.resp) != C.RET_OK {
		return "", bridge.callError("cGoCodexUploadInit")
	}

	return bridge.wait()
}

// UploadChunk uploads a chunk of data to the Codex node.
// It takes the session ID returned by UploadInit
// and a byte slice containing the chunk data.
// This function is called by UploadReader internally.
// You should use this function only if you need to manage the upload session manually.
func (node CodexNode) UploadChunk(sessionId string, chunk []byte) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	var cChunkPtr *C.uint8_t
	if len(chunk) > 0 {
		cChunkPtr = (*C.uint8_t)(unsafe.Pointer(&chunk[0]))
	}

	if C.cGoCodexUploadChunk(node.ctx, cSessionId, cChunkPtr, C.size_t(len(chunk)), bridge.resp) != C.RET_OK {
		return bridge.callError("cGoCodexUploadChunk")
	}

	_, err := bridge.wait()
	return err
}

// UploadFinalize finalizes the upload session and returns the CID of the uploaded file.
// It takes the session ID returned by UploadInit.
// This function is called by UploadReader and UploadFile internally.
// You should use this function only if you need to manage the upload session manually.
func (node CodexNode) UploadFinalize(sessionId string) (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadFinalize(node.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return "", bridge.callError("cGoCodexUploadFinalize")
	}

	return bridge.wait()
}

// UploadCancel cancels an ongoing upload session.
// It can be only if the upload session is managed manually.
// It doesn't work with UploadFile.
func (node CodexNode) UploadCancel(sessionId string) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadCancel(node.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return bridge.callError("cGoCodexUploadCancel")
	}

	_, err := bridge.wait()
	return err
}

// UploadReader uploads data from an io.Reader to the Codex node.
// It takes the upload options and the reader as parameters.
// It returns the CID of the uploaded file or an error.
//
// Internally, it calls:
// - UploadInit to create the upload session.
// - UploadChunk to upload a chunk to codex.
// - UploadFinalize to finalize the upload session.
// - UploadCancel if an error occurs.
func (node CodexNode) UploadReader(options UploadOptions, r io.Reader) (string, error) {
	sessionId, err := node.UploadInit(&options)
	if err != nil {
		return "", err
	}

	buf := make([]byte, options.ChunkSize.valOrDefault())
	total := 0

	var size int64
	if options.OnProgress != nil {
		size = getReaderSize(r)
	}

	for {
		n, err := r.Read(buf)
		if err == io.EOF {
			break
		}

		if err != nil {
			if cancelErr := node.UploadCancel(sessionId); cancelErr != nil {
				return "", fmt.Errorf("failed to upload chunk %v and failed to cancel upload session %v", err, cancelErr)
			}

			return "", err
		}

		if n == 0 {
			break
		}

		if err := node.UploadChunk(sessionId, buf[:n]); err != nil {
			if cancelErr := node.UploadCancel(sessionId); cancelErr != nil {
				return "", fmt.Errorf("failed to upload chunk %v and failed to cancel upload session %v", err, cancelErr)
			}

			return "", err
		}

		total += n
		if options.OnProgress != nil && size > 0 {
			percent := float64(total) / float64(size) * 100.0
			// The last block could be a bit over the size due to padding
			// on the chunk size.
			if percent > 100.0 {
				percent = 100.0
			}
			options.OnProgress(n, total, percent, nil)
		} else if options.OnProgress != nil {
			options.OnProgress(n, total, 0, nil)
		}
	}

	return node.UploadFinalize(sessionId)
}

// UploadReaderAsync is the asynchronous version of UploadReader using a goroutine.
func (node CodexNode) UploadReaderAsync(options UploadOptions, r io.Reader, onDone func(cid string, err error)) {
	go func() {
		cid, err := node.UploadReader(options, r)
		onDone(cid, err)
	}()
}

// UploadFile uploads a file to the Codex node.
// It takes the upload options as parameter.
// It returns the CID of the uploaded file or an error.
//
// The options parameter contains the following fields:
// - filepath: the full path of the file to upload.
// - chunkSize: the size of each upload chunk, passed as `blockSize` to the Codex node
// store. Default is to 64 KB.
// - onProgress: a callback function that is called after each chunk is uploaded with:
//   - read: the number of bytes read in the last chunk.
//   - total: the total number of bytes read so far.
//   - percent: the percentage of the total file size that has been uploaded. It is
//     determined from a `stat` call.
//   - err: an error, if one occurred.
//
// If the chunk size is more than the `chunkSize` parameter, the callback is called after
// the block is actually stored in the block store. Otherwise, it is called after the chunk
// is sent to the stream.
//
// Internally, it calls UploadInit to create the upload session.
func (node CodexNode) UploadFile(options UploadOptions) (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if options.OnProgress != nil {
		stat, err := os.Stat(options.Filepath)
		if err != nil {
			return "", err
		}

		size := stat.Size()
		total := 0

		if size > 0 {
			bridge.onProgress = func(read int, _ []byte) {
				if read == 0 {
					return
				}

				total += read
				percent := float64(total) / float64(size) * 100.0
				// The last block could be a bit over the size due to padding
				// on the chunk size.
				if percent > 100.0 {
					percent = 100.0
				}

				options.OnProgress(read, int(size), percent, nil)
			}
		}
	}

	sessionId, err := node.UploadInit(&options)
	if err != nil {
		return "", err
	}

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadFile(node.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return "", bridge.callError("cGoCodexUploadFile")
	}

	return bridge.wait()
}

// UploadFileAsync is the asynchronous version of UploadFile using a goroutine.
func (node CodexNode) UploadFileAsync(options UploadOptions, onDone func(cid string, err error)) {
	go func() {
		cid, err := node.UploadFile(options)
		onDone(cid, err)
	}()
}

func (node CodexNode) UpdateLogLevel(logLevel string) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cLogLevel = C.CString(string(logLevel))
	defer C.free(unsafe.Pointer(cLogLevel))

	if C.cGoCodexLogLevel(node.ctx, cLogLevel, bridge.resp) != C.RET_OK {
		return bridge.callError("cGoCodexLogLevel")
	}

	_, err := bridge.wait()
	return err
}

func (node CodexNode) Exists(cid string) (bool, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cCid = C.CString(cid)
	defer C.free(unsafe.Pointer(cCid))

	if C.cGoCodexExists(node.ctx, cCid, bridge.resp) != C.RET_OK {
		return false, bridge.callError("cGoCodexUploadCancel")
	}

	result, err := bridge.wait()
	return result == "true", err
}

func main() {
	dataDir := os.TempDir() + "/data-dir"

	node, err := New(Config{
		BlockRetries: 5,
		LogLevel:     "WARN",
		DataDir:      dataDir,
	})
	if err != nil {
		log.Fatalf("Failed to create Codex node: %v", err)
	}
	defer os.RemoveAll(dataDir)

	if err := node.Start(); err != nil {
		log.Fatalf("Failed to start Codex node: %v", err)
	}
	log.Println("Codex node started")

	version, err := node.Version()
	if err != nil {
		log.Fatalf("Failed to get Codex version: %v", err)
	}
	log.Printf("Codex version: %s", version)

	err = node.UpdateLogLevel("ERROR")
	if err != nil {
		log.Fatalf("Failed to update log level: %v", err)
	}

	cid := "zDvZRwzmAkhzDRPH5EW242gJBNZ2T7aoH2v1fVH66FxXL4kSbvyM"
	exists, err := node.Exists(cid)
	if err != nil {
		log.Fatalf("Failed to check data existence: %v", err)
	}

	if exists {
		log.Fatalf("The data should not exist")
	}

	buf := bytes.NewBuffer([]byte("Hello World!"))
	len := buf.Len()
	cid, err = node.UploadReader(UploadOptions{Filepath: "hello.txt"}, buf)
	if err != nil {
		log.Fatalf("Failed to upload data: %v", err)
	}
	log.Printf("Uploaded data with CID: %s (size: %d bytes)", cid, len)

	exists, err = node.Exists(cid)
	if err != nil {
		log.Fatalf("Failed to check data existence: %v", err)
	}

	if !exists {
		log.Fatalf("The data should exist")
	}

	// Wait for a SIGINT or SIGTERM signal
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch

	if err := node.Stop(); err != nil {
		log.Fatalf("Failed to stop Codex node: %v", err)
	}
	log.Println("Codex node stopped")

	if err := node.Destroy(); err != nil {
		log.Fatalf("Failed to destroy Codex node: %v", err)
	}
}
