package main

/*
	#cgo LDFLAGS: -L../../build/ -lcodex
	#cgo LDFLAGS: -L../../ -Wl,-rpath,../../

	#include "../../library/libcodex.h"
	#include <stdio.h>
	#include <stdlib.h>
	#include <stdint.h>

	void libcodexNimMain(void);
	static void codex_host_init_once(void){
		static int done;
		if (!__atomic_exchange_n(&done, 1, __ATOMIC_SEQ_CST)) libcodexNimMain();
	}

	extern void globalEventCallback(int ret, char* msg, size_t len, void* userData);

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

	static char* getMyCharPtr(void* resp) {
		if (resp == NULL) {
			return NULL;
		}
		Resp* m = (Resp*) resp;
		return m->msg;
	}

	static size_t getMyCharLen(void* resp) {
		if (resp == NULL) {
			return 0;
		}
		Resp* m = (Resp*) resp;
		return m->len;
	}

	// resp must be set != NULL in case interest on retrieving data from the callback
	void callback(int ret, char* msg, size_t len, void* resp);

	static void* cGoCodexNew(const char* configJson, void* resp) {
		void* ret = codex_new(configJson, (CodexCallback) callback, resp);
		return ret;
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

	static int cGoCodexDebug(void* codexCtx, void* resp) {
		return codex_debug(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexSpr(void* codexCtx, void* resp) {
		return codex_spr(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexPeerId(void* codexCtx, void* resp) {
		return codex_peer_id(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexLogLevel(void* codexCtx, char* logLevel, void* resp) {
		return codex_log_level(codexCtx, logLevel, (CodexCallback) callback, resp);
	}

	static int cGoCodexConnect(void* codexCtx, char* peerId, const char** peerAddresses, uintptr_t peerAddressesSize,  void* resp) {
		return codex_connect(codexCtx, peerId, peerAddresses, peerAddressesSize, (CodexCallback) callback, resp);
	}

	static int cGoCodexPeerDebug(void* codexCtx, char* peerId, void* resp) {
		return codex_peer_debug(codexCtx, peerId, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadInit(void* codexCtx, char* mimetype, char* filename, void* resp) {
		return codex_upload_init(codexCtx, mimetype, filename, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadChunk(void* codexCtx, char* sessionId, const uint32_t* chunk, size_t len, void* resp) {
		return codex_upload_chunk(codexCtx, sessionId, chunk, len, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadFinalize(void* codexCtx, char* sessionId, void* resp) {
		return codex_upload_finalize(codexCtx, sessionId, (CodexCallback) callback, resp);
	}

	static int cGoCodexUploadCancel(void* codexCtx, char* sessionId, void* resp) {
		return codex_upload_cancel(codexCtx, sessionId, (CodexCallback) callback, resp);
	}

	static int cGoCodexStart(void* codexCtx, void* resp) {
		return codex_start(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexStop(void* codexCtx, void* resp) {
		return codex_stop(codexCtx, (CodexCallback) callback, resp);
	}

	static int cGoCodexDestroy(void* codexCtx, void* resp) {
		return codex_destroy(codexCtx, (CodexCallback) callback, resp);
	}

	static void cGoCodexSetEventCallback(void* codexCtx) {
		// The 'globalEventCallback' Go function is shared amongst all possible Codex instances.

		// Given that the 'globalEventCallback' is shared, we pass again the
		// codexCtx instance but in this case is needed to pick up the correct method
		// that will handle the event.

		// In other words, for every call the libcodex makes to globalEventCallback,
		// the 'userData' parameter will bring the context of the node that registered
		// that globalEventCallback.

		// This technique is needed because cgo only allows to export Go functions and not methods.

		codex_set_event_callback(codexCtx, (CodexCallback) globalEventCallback, codexCtx);
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

type LogLevel string

const (
	Trace  LogLevel = "TRACE"
	Debug  LogLevel = "DEBUG"
	Info   LogLevel = "INFO"
	Notice LogLevel = "NOTICE"
	Warn   LogLevel = "WARN"
	Error  LogLevel = "ERROR"
	Fatal  LogLevel = "FATAL"
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

type CodexConfig struct {
	LogFormat                      LogFormat `json:"log-format,omitempty"`
	MetricsEnabled                 bool      `json:"metrics,omitempty"`
	MetricsAddress                 string    `json:"metrics-address,omitempty"`
	DataDir                        string    `json:"data-dir,omitempty"`
	ListenAddrs                    []string  `json:"listen-addrs,omitempty"`
	Nat                            string    `json:"nat,omitempty"`
	DiscoveryPort                  int       `json:"disc-port,omitempty"`
	NetPrivKeyFile                 string    `json:"net-privkey,omitempty"`
	BootstrapNodes                 []byte    `json:"bootstrap-node,omitempty"`
	MaxPeers                       int       `json:"max-peers,omitempty"`
	NumThreads                     int       `json:"num-threads,omitempty"`
	AgentString                    string    `json:"agent-string,omitempty"`
	RepoKind                       RepoKind  `json:"repo-kind,omitempty"`
	StorageQuota                   int       `json:"storage-quota,omitempty"`
	BlockTtl                       int       `json:"block-ttl,omitempty"`
	BlockMaintenanceInterval       int       `json:"block-mi,omitempty"`
	BlockMaintenanceNumberOfBlocks int       `json:"block-mn,omitempty"`
	CacheSize                      int       `json:"cache-size,omitempty"`
	LogFile                        string    `json:"log-file,omitempty"`
}

type RestPeerRecord struct {
	PeerId    string   `json:"peerId"`
	SeqNo     int      `json:"seqNo"`
	Addresses []string `json:"addresses,omitempty"`
}

type RestNode struct {
	NodeId  string  `json:"nodeId"`
	PeerId  string  `json:"peerId"`
	Record  string  `json:"record"`
	Address *string `json:"address"` // Use pointer for nullable
	Seen    bool    `json:"seen"`
}

type RestRoutingTable struct {
	LocalNode RestNode   `json:"localNode"`
	Nodes     []RestNode `json:"nodes"`
}

type CodexDebugInfo struct {
	ID                string           `json:"id"`
	Addrs             []string         `json:"addrs"`
	Spr               string           `json:"spr"`
	AnnounceAddresses []string         `json:"announceAddresses"`
	Table             RestRoutingTable `json:"table"`
}

type CodexNode struct {
	ctx unsafe.Pointer
}

type bridgeCtx struct {
	wg     *sync.WaitGroup
	h      cgo.Handle
	resp   unsafe.Pointer
	result string
	err    error
}

func newBridgeCtx() *bridgeCtx {
	var wg sync.WaitGroup
	wg.Add(1)

	bridge := &bridgeCtx{wg: &wg}
	bridge.h = cgo.NewHandle(bridge)
	bridge.resp = C.allocResp(C.uintptr_t(uintptr(bridge.h)))

	return bridge
}

func (b *bridgeCtx) free() {
	C.freeResp(b.resp)
	b.resp = nil
}

func (b *bridgeCtx) isOK() bool {
	return C.getRet(b.resp) == C.RET_OK
}

func (b *bridgeCtx) isError() bool {
	return C.getRet(b.resp) == C.RET_ERR
}

func (b *bridgeCtx) CallError(name string) error {
	return fmt.Errorf("Failed the call to %s. Returned code: %d.", name, C.getRet(b.resp))
}

func (b *bridgeCtx) wait() (string, error) {
	b.wg.Wait()

	return b.result, b.err
}

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
		if ret == C.RET_OK || ret == C.RET_ERR {
			retMsg := C.GoStringN(msg, C.int(len))

			// log.Println("Callback called with ret:", ret, " msg:", retMsg, " len:", len)

			if ret == C.RET_OK {
				v.result = retMsg
			} else {
				v.err = errors.New(retMsg)
			}

			h.Delete()
			m.h = 0

			if v.wg != nil {
				v.wg.Done()
				v = nil
			}
		}
	}
}

func CodexNew(config CodexConfig) (*CodexNode, error) {
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

func (self *CodexNode) CodexVersion() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexVersion(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexVersion")
	}

	return bridge.wait()
}

func (self *CodexNode) CodexRevision() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexRevision(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexRevision")
	}

	return bridge.wait()
}

func (self *CodexNode) CodexRepo() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexRepo(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexRepo")
	}

	return bridge.wait()
}

func (self *CodexNode) CodexDebug() (CodexDebugInfo, error) {
	var info CodexDebugInfo

	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexDebug(self.ctx, bridge.resp) != C.RET_OK {
		return info, bridge.CallError("cGoCodexDebug")
	}

	value, err := bridge.wait()
	if err != nil {
		return info, err
	}

	err = json.Unmarshal([]byte(value), &info)

	return info, err
}

func (self *CodexNode) CodexSpr() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexSpr(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexSpr")
	}

	return bridge.wait()
}

func (self *CodexNode) CodexPeerId() (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexPeerId(self.ctx, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexPeerId")
	}

	return bridge.wait()
}

func (self *CodexNode) CodexLogLevel(logLevel LogLevel) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cLogLevel = C.CString(fmt.Sprintf("%s", logLevel))
	defer C.free(unsafe.Pointer(cLogLevel))

	if C.cGoCodexLogLevel(self.ctx, cLogLevel, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexLogLevel")
	}

	_, err := bridge.wait()
	return err
}

func (self *CodexNode) CodexConnect(peerId string, peerAddresses []string) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cPeerId = C.CString(peerId)
	defer C.free(unsafe.Pointer(cPeerId))

	if len(peerAddresses) > 0 {
		var cAddresses = make([]*C.char, len(peerAddresses))
		for i, addr := range peerAddresses {
			cAddresses[i] = C.CString(addr)
			defer C.free(unsafe.Pointer(cAddresses[i]))
		}

		if C.cGoCodexConnect(self.ctx, cPeerId, &cAddresses[0], C.uintptr_t(len(peerAddresses)), bridge.resp) != C.RET_OK {
			return bridge.CallError("cGoCodexConnect")
		}
	} else {
		if C.cGoCodexConnect(self.ctx, cPeerId, nil, 0, bridge.resp) != C.RET_OK {
			return bridge.CallError("cGoCodexConnect")
		}
	}

	_, err := bridge.wait()
	return err
}

func (self *CodexNode) CodexPeerDebug(peerId string) (RestPeerRecord, error) {
	var record RestPeerRecord

	bridge := newBridgeCtx()
	defer bridge.free()

	var cPeerId = C.CString(peerId)
	defer C.free(unsafe.Pointer(cPeerId))

	if C.cGoCodexPeerDebug(self.ctx, cPeerId, bridge.resp) != C.RET_OK {
		return record, bridge.CallError("cGoCodexPeerDebug")
	}

	value, err := bridge.wait()
	if err != nil {
		return record, err
	}

	err = json.Unmarshal([]byte(value), &record)

	return record, err
}

func (self *CodexNode) CodexUploadInit(mimetype, filename string) (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cMimetype = C.CString(mimetype)
	defer C.free(unsafe.Pointer(cMimetype))

	var cFilename = C.CString(filename)
	defer C.free(unsafe.Pointer(cFilename))

	if C.cGoCodexUploadInit(self.ctx, cMimetype, cFilename, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexUploadInit")
	}

	return bridge.wait()
}

func (self *CodexNode) CodexUploadChunk(sessionId string, chunk []byte) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	var cChunkPtr *C.uint32_t
	if len(chunk) > 0 {
		cChunkPtr = (*C.uint32_t)(unsafe.Pointer(&chunk[0]))
	}

	if C.cGoCodexUploadChunk(self.ctx, cSessionId, cChunkPtr, C.size_t(len(chunk)), bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexUploadChunk")
	}

	_, err := bridge.wait()
	return err
}

func (self *CodexNode) CodexUploadFinalize(sessionId string) (string, error) {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadFinalize(self.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return "", bridge.CallError("cGoCodexUploadFinalize")
	}

	return bridge.wait()
}

func (self *CodexNode) CodexUploadCancel(sessionId string) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	var cSessionId = C.CString(sessionId)
	defer C.free(unsafe.Pointer(cSessionId))

	if C.cGoCodexUploadCancel(self.ctx, cSessionId, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexUploadCancel")
	}

	_, err := bridge.wait()
	return err
}

func (self *CodexNode) CodexUploadReader(mimetype, filename string, r io.Reader, chunkSize int) (string, error) {
	sessionId, err := self.CodexUploadInit(mimetype, filename)
	if err != nil {
		return "", err
	}

	buf := make([]byte, chunkSize)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			if err := self.CodexUploadChunk(sessionId, buf[:n]); err != nil {
				return "", err
			}
		}

		if err == io.EOF {
			break
		}

		if err != nil {
			self.CodexUploadCancel(sessionId)

			return "", err
		}
	}

	return self.CodexUploadFinalize(sessionId)
}

func (self *CodexNode) CodexStart() error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexStart(self.ctx, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexStart")
	}

	_, err := bridge.wait()
	return err
}

func (self *CodexNode) CodexStartAsync(cb func(error)) error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexStart(self.ctx, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexStart")
	}

	go func() {
		_, err := bridge.wait()
		cb(err)
	}()

	return nil
}

func (self *CodexNode) CodexStop() error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexStop(self.ctx, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexStop")
	}

	_, err := bridge.wait()
	return err
}

func (self *CodexNode) CodexDestroy() error {
	bridge := newBridgeCtx()
	defer bridge.free()

	if C.cGoCodexDestroy(self.ctx, bridge.resp) != C.RET_OK {
		return bridge.CallError("cGoCodexDestroy")
	}

	_, err := bridge.wait()
	return err
}

//export globalEventCallback
func globalEventCallback(callerRet C.int, msg *C.char, len C.size_t, userData unsafe.Pointer) {
	// This is shared among all Golang instances

	self := CodexNode{ctx: userData}
	self.MyEventCallback(callerRet, msg, len)
}

func (self *CodexNode) MyEventCallback(callerRet C.int, msg *C.char, len C.size_t) {
	log.Println("Event received:", C.GoStringN(msg, C.int(len)))
}

func (self *CodexNode) CodexSetEventCallback() {
	// Notice that the events for self node are handled by the 'MyEventCallback' method
	C.cGoCodexSetEventCallback(self.ctx)
}

func main() {
	config := CodexConfig{}

	node, err := CodexNew(config)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex created.")

	// node.CodexSetEventCallback()

	version, err := node.CodexVersion()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex version:", version)

	revision, err := node.CodexRevision()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex revision:", revision)

	repo, err := node.CodexRepo()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex repo:", repo)

	log.Println("Starting Codex...")

	err = node.CodexStart()

	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex started...")

	debug, err := node.CodexDebug()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	pretty, err := json.MarshalIndent(debug, "", "  ")
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println(string(pretty))

	spr, err := node.CodexSpr()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex SPR:", spr)

	peerId, err := node.CodexPeerId()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Peer Id:", peerId)

	err = node.CodexLogLevel(Trace)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Log Level set to TRACE")

	sessionId, err := node.CodexUploadInit("text/plain", "hello.txt")
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Upload Init sessionId:", sessionId)

	err = node.CodexUploadChunk(sessionId, []byte("Hello "))
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	err = node.CodexUploadChunk(sessionId, []byte("World!"))
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	cid, err := node.CodexUploadFinalize(sessionId)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Upload Finalized, cid:", cid)

	buf := bytes.NewBuffer([]byte("Hello World!"))
	cid, err = node.CodexUploadReader("text/plain", "hello.txt", buf, 16*1024)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex Upload Finalized from reader, cid:", cid)

	// err = node.CodexConnect(peerId, []string{})
	// if err != nil {
	// 	log.Fatal("Error happened:", err.Error())
	// }

	// log.Println("Codex connecting to self...")

	// val, err := node.CodexPeerDebug(peerId)
	// if err != nil {
	// 	log.Fatal("Error happened:", err.Error())
	// }

	// log.Println("Codex debugging self...", val)

	// Wait for a SIGINT or SIGTERM signal
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch

	log.Println("Stopping the node...")

	err = node.CodexStop()

	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex stopped...")

	log.Println("Destroying the node...")

	err = node.CodexDestroy()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}
}
