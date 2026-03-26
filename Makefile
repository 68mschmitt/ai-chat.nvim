.PHONY: test test-file lint format clean

MINIMAL_INIT := tests/minimal_init.lua

# Run all plenary.busted tests
# Uses --noplugin for a clean environment; minimal_init.lua bootstraps plenary
# and explicitly sources its plugin file to register PlenaryBustedDirectory.
test:
	nvim --headless --noplugin -u $(MINIMAL_INIT) \
		-c "PlenaryBustedDirectory tests/ {minimal_init = '$(MINIMAL_INIT)'}"

# Run the v0.1 verification tests
verify:
	nvim --headless --clean -u $(MINIMAL_INIT) -l tests/verify.lua

# Run a single test file (usage: make test-file FILE=tests/util/tokens_spec.lua)
test-file:
	nvim --headless --noplugin -u $(MINIMAL_INIT) \
		-c "PlenaryBustedFile $(FILE)"

# Check formatting (CI uses this)
lint:
	stylua --check lua/ tests/

# Auto-format
format:
	stylua lua/ tests/

# Remove test dependencies
clean:
	rm -rf .deps/
