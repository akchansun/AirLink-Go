package engine

import (
	"encoding/base64"
	"sync"

	qrcode "github.com/skip2/go-qrcode"
)

var (
	qrMu       sync.Mutex
	qrLastURL  string
	qrLastData string
)

func PhoneQRDataURI(url string) string {
	if url == "" {
		return ""
	}
	qrMu.Lock()
	defer qrMu.Unlock()
	if url == qrLastURL {
		return qrLastData
	}
	png, err := qrcode.Encode(url, qrcode.Medium, 240)
	if err != nil {
		qrLastURL = url
		qrLastData = ""
		return ""
	}
	data := "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)
	qrLastURL = url
	qrLastData = data
	return data
}
