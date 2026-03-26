.PHONY: test test-file lint format clean

MINIMAL_INIT := tests/minimal_init.lua

# Run all plenary.busted tests
# Uses the Lua API directly instead of the PlenaryBustedDirectory ex command
# for reliable behavior across local and CI environments.
test:
	nvim --headless --noplugin -u $(MINIMAL_INIT) \
		-c "lua require('plenary.test_harness').test_directory('tests', {minimal_init = '$(MINIMAL_INIT)', sequential = true})"

# Run the v0.1 verification tests
verify:
	nvim --headless --clean -u $(MINIMAL_INIT) -l tests/verify.lua

# Run a single test file (usage: make test-file FILE=tests/util/tokens_spec.lua)
test-file:
	nvim --headless --noplugin -u $(MINIMAL_INIT) \
		-c "lua require('plenary.test_harness').test_directory('$(FILE)', {minimal_init = '$(MINIMAL_INIT)'})"

# Check formatting (CI uses this)
lint:
	stylua --check lua/ tests/

# Auto-format
format:
	stylua lua/ tests/

# Remove test dependencies
clean:
	rm -rf .deps/
