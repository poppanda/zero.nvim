.PHONY: build clean test test-lua test-rust smoke-neogit smoke-gitsigns

build:
	cd daemon && cargo build

clean:
	rm -f /tmp/zero-daemon.log

test: test-rust test-lua

test-rust:
	cd daemon && cargo test

test-lua:
	bash scripts/run_tests.sh

# 需要 fork neogit（ZERO_NEOGIT_ROOT，默认 ../neogit）+ plenary.nvim
smoke-neogit:
	bash scripts/smoke_neogit_backend.sh

# 需要真实远端：ZERO_TEST_USER / ZERO_TEST_HOST / ZERO_TEST_PATH [/ ZERO_TEST_PORT]
smoke-gitsigns:
	bash scripts/smoke_gitsigns_remote.sh
