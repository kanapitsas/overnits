PREFIX ?= /usr/local
BIN    := overnits

all: $(BIN)

$(BIN): main.swift
	swiftc -O main.swift -o $(BIN)

install: $(BIN)
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 $(BIN) "$(DESTDIR)$(PREFIX)/bin/$(BIN)"

clean:
	rm -f $(BIN)

.PHONY: all install clean
