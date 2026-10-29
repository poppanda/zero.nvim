.PHONY: build clean test test-lua test-rust

build:
	cd daemon && cargo build

clean:
	rm -f /tmp/daemon_ssh* /tmp/debug_ssh_raw.log

test: test-rust test-lua

test-rust:
	cd daemon && cargo test

test-lua:
	bash scripts/run_tests.sh
