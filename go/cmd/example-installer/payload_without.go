//go:build !withpayload

package main

// payload is empty in a default build (no embedded archive), so `go build
// ./...`, `go test`, and `go vet` all work without a generated
// payload.tar.gz present. The real payload is embedded only under
// `-tags withpayload` (see payload_with.go).
var payload []byte
