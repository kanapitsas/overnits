PREFIX ?= /usr/local
BIN    := overnits
# Sans -target, swiftc vise la version de macOS de la machine de build, ce qui
# contredit le "macOS 12 or later" du README pour un binaire distribue.
ARCH        ?= $(shell uname -m)
MACOS_MIN   ?= 12.0

all: $(BIN)

$(BIN): main.swift
	swiftc -O -target $(ARCH)-apple-macos$(MACOS_MIN) main.swift -o $(BIN)

install: $(BIN)
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 $(BIN) "$(DESTDIR)$(PREFIX)/bin/$(BIN)"

clean:
	rm -f $(BIN)

.PHONY: all install clean
