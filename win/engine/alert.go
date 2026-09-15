package engine

import "sync"

var (
	alertMu   sync.Mutex
	alertHook func(title, body string)
)

func SetAlertHook(fn func(title, body string)) {
	alertMu.Lock()
	alertHook = fn
	alertMu.Unlock()
}

func Alert(title, body string) {
	alertMu.Lock()
	fn := alertHook
	alertMu.Unlock()
	if fn != nil {
		fn(title, body)
	}
}
