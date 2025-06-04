build:
  zig build

install: build
  cp zig-out/bin/* ~/.local/bin
