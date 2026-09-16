package target

import (
	"fmt"
	"strings"
)

// systemd's set of characters that survive escaping unchanged.
// Note that '-' is NOT in this set: a literal dash becomes \x2d, because '-'
// is how a path separator is encoded and the two must not collide.
func unitNameSafe(r byte) bool {
	switch {
	case r >= 'a' && r <= 'z',
		r >= 'A' && r <= 'Z',
		r >= '0' && r <= '9':
		return true
	}
	return r == ':' || r == '_' || r == '.'
}

// EscapeUnitName implements systemd's unit_name_escape — the transform
// `systemd-escape` applies with no flags.
//
// Every byte outside [a-zA-Z0-9:_.] becomes \xNN (lowercase hex), '/' becomes
// '-', and a LEADING '.' becomes \x2e so a unit file can never begin with a
// dot and vanish from a directory listing.
func EscapeUnitName(s string) string {
	if s == "" {
		return ""
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case i == 0 && c == '.':
			b.WriteString(`\x2e`)
		case c == '/':
			b.WriteByte('-')
		case unitNameSafe(c):
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, `\x%02x`, c)
		}
	}
	return b.String()
}

// EscapePath implements systemd's unit_name_path_escape — `systemd-escape
// --path`. This is the transform that DERIVES a .mount unit's filename, and
// getting it wrong does not produce an error: systemd simply never associates
// the unit with the mount point, so the unit sits there being ignored.
//
//	/            -> -
//	/mnt/data    -> mnt-data
//	/mnt/my-disk -> mnt-my\x2ddisk
func EscapePath(p string) string {
	// Collapse duplicate slashes and drop "." segments, the way path_simplify
	// does, then strip the leading and trailing separators.
	parts := strings.Split(p, "/")
	kept := make([]string, 0, len(parts))
	for _, seg := range parts {
		if seg == "" || seg == "." {
			continue
		}
		kept = append(kept, seg)
	}
	joined := strings.Join(kept, "/")
	if joined == "" {
		// The root path is the one unit name that is a bare dash.
		return "-"
	}
	return EscapeUnitName(joined)
}
