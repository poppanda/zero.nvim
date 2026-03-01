.PHONY: build clean
build:
	cd daemon && cargo build

clean:
	rm /tmp/daemon_ssh* /tmp/debug_ssh_raw.log

test: build clean
