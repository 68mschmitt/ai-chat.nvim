.PHONY: test test-file verify lint format clean

MINIMAL_INIT := tests/minimal_init.lua

# Run all tests
test:
	nvim --headless --noplugin -u $(MINIMAL_INIT) \
		-c "luafile tests/runner.lua"

# Run the v0.1 verification tests
verify:
	nvim --headless --clean -u $(MINIMAL_INIT) -l tests/verify.lua

# Run a single test file (usage: make test-file FILE=tests/util/tokens_spec.lua)
test-file:
	nvim --headless --noplugin -u $(MINIMAL_INIT) \
		-c "lua _G._test_file = '$(FILE)'" \
		-c "luafile tests/runner.lua"

# Check formatting (CI uses this)
lint:
	stylua --check lua/ tests/

# Auto-format
format:
	stylua lua/ tests/

# Remove test artifacts
clean:
	rm -rf .deps/
