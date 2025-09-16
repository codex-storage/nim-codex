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

	static void* allocResp() {
		return calloc(1, sizeof(Resp));
	}

	static void* allocRespWithHandle(uintptr_t h) {
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
	"encoding/json"
	"errors"
	"fmt"
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
	LogLevel                       LogLevel  `json:"log-level,omitempty"`
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
	bridge.resp = C.allocRespWithHandle(C.uintptr_t(uintptr(bridge.h)))

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
	return errors.New(
		fmt.Sprintf("Failed the call to %s. Returned code: %d.", name, C.getRet(b.resp)),
	)
}

func (b *bridgeCtx) wait() (string, error) {
	b.wg.Wait()

	return b.result, b.err
}

func (b *bridgeCtx) getMsg() string {
	return C.GoStringN(C.getMyCharPtr(b.resp), C.int(C.getMyCharLen(b.resp)))
}

//export callback
func callback(ret C.int, msg *C.char, len C.size_t, resp unsafe.Pointer) {
	if resp == nil {
		return
	}

	// log.Println("Callback called with ret:", ret, " msg:", C.GoStringN(msg, C.int(len)), " len:", len)

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
	config := CodexConfig{
		LogLevel: Info,
	}

	log.Println("Creating Codex...")

	node, err := CodexNew(config)
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex created.")

	// node.CodexSetEventCallback()

	log.Println("Getting version...")

	version, err := node.CodexVersion()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex version:", version)

	log.Println("Getting revision...")

	revision, err := node.CodexRevision()
	if err != nil {
		log.Fatal("Error happened:", err.Error())
	}

	log.Println("Codex revision:", revision)

	log.Println("Getting repo...")

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
