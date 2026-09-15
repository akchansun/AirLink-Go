module huchuan

go 1.25.0

require (
	github.com/grandcat/zeroconf v1.0.0
	github.com/jchv/go-webview2 v0.0.0-20260205173254-56598839c808
	github.com/skip2/go-qrcode v0.0.0-20200617195104-da1b6568686e
	golang.org/x/sys v0.47.0
)

require (
	github.com/cenkalti/backoff v2.2.1+incompatible // indirect
	github.com/jchv/go-winloader v0.0.0-20250406163304-c1995be93bd1 // indirect
	github.com/miekg/dns v1.1.73 // indirect
	golang.org/x/net v0.58.0 // indirect
)

replace github.com/skip2/go-qrcode => ./third_party/go-qrcode
