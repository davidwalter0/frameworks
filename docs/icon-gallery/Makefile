# Regenerates every family app icon from its spec, re-measures the results, and
# refreshes the gallery page. Run from this directory: `make`.
#
# The gallery is the single generation point for the family's icons: specs live
# here, and each consuming repo receives only the GENERATED svg/png. That keeps
# one licensed font in one place instead of a copy per repo — see fonts/.

SIZES  := 512,256,128,64,48,32
APPS   := ghk word-bank voicelab mountbridge cross-bridge netroute-manager
GO     ?= go
# This directory is OUTSIDE the Go module (which lives at ../../go), so
# `go run ../../go/cmd/gen-icon` fails with "cannot find main module". Build the
# binary from inside the module instead and invoke it by path.
GENICON := $(CURDIR)/bin/gen-icon

.PHONY: all icons sample clean open

all: sample

$(GENICON):
	@mkdir -p $(dir $@)
	@cd ../../go && $(GO) build -o $@ ./cmd/gen-icon

## icons: render svg + every hicolor png size for each app
icons: $(GENICON)
	@mkdir -p out
	@for app in $(APPS); do \
	  mkdir -p out/$$app; \
	  $(GENICON) --spec specs/$$app.json \
	    --svg out/$$app/$$app.svg \
	    --png-dir out/$$app --sizes $(SIZES) --png-pattern "$$app-%d.png" \
	    >/dev/null || exit 1; \
	  echo "  rendered $$app"; \
	done

## sample: measure every rendered PNG and write the gallery's data file
##
## Not decoration: an icon whose glyph failed to draw still produces a
## plausible-looking tile, and only the ink/corner numbers distinguish it.
sample: icons
	@$(GO) run icon-sample.go out/*/*.png > sample.txt
	@$(GO) run icon-sample.go out/*/*.png | \
	  sed -nE 's#.*/([A-Za-z0-9-]+)-([0-9]+)\.png +([0-9]+)x[0-9]+ +corner (\S+) +centre (\S+) +colors ([0-9]+) +ink +([0-9.]+)%.*#\1 \2 \4 \5 \6 \7#p' | \
	  awk 'BEGIN{print "{"} \
	       {if($$1!=prev){if(prev!="")printf "\n },\n"; printf " \"%s\": {", $$1; prev=$$1; first=1} \
	        if(!first)printf ","; printf "\n  \"%s\": {\"corner\":\"%s\",\"centre\":\"%s\",\"colors\":%s,\"ink\":%s}", $$2,$$3,$$4,$$5,$$6; first=0} \
	       END{print "\n }\n}"}' > sample.json
	@echo "  wrote sample.json"

## open: view the gallery
open:
	@xdg-open index.html >/dev/null 2>&1 || echo "open index.html in a browser"

clean:
	rm -rf out bin sample.txt sample.json
