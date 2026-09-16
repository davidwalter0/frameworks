//go:build withpayload

package main

import _ "embed"

// payload is the embedded gzip-compressed tar of the staged voicelab install
// tree, produced by voicelab's scripts/package-linux.sh and copied here as
// payload.tar.gz immediately before this is compiled with `-tags withpayload`.
//
//go:embed payload.tar.gz
var payload []byte
