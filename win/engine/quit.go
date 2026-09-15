package engine

import (
	"os"
	"sync"
)

var (
	quitMu   sync.Mutex
	quitHook func()
)

func SetQuitHook(fn func()) {
	quitMu.Lock()
	quitHook = fn
	quitMu.Unlock()
}

func RequestQuit() {
	quitMu.Lock()
	fn := quitHook
	quitMu.Unlock()
	if fn != nil {
		fn()
		return
	}
	os.Exit(0)
}
