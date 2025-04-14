all: build setsuid

build:
	zig build

install:
	sudo cp zig-out/bin/* ~/.local/bin/

	sudo chown root:root ~/.local/bin/beelightd
	sudo chmod u+s ~/.local/bin/beelightd
	sudo chown root:root ~/.local/bin/beelight
	sudo chmod u+s ~/.local/bin/beelight

test:
	zig build test

setsuid:
	sudo chown root:root zig-out/bin/beelightd
	sudo chmod u+s zig-out/bin/beelightd

	sudo chown root:root zig-out/bin/beelight
	sudo chmod u+s zig-out/bin/beelight

.PHONY: clean
clean:
