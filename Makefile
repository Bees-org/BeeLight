all: build setsuid

build:
	zig build

install:
	cp zig-out/bin/* ~/.local/bin/

test:
	zig build test

.PHONY: clean
clean:
