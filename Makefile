.PHONY: test test-file lint clean

MINIMAL_INIT := tests/minimal_init.lua

# Run all plenary.busted tests
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

# Lint (when stylua/luacheck are configured)
lint:
	@echo "No linter configured yet (planned for v1.0)"

# Remove test dependencies
clean:
	rm -rf .deps/
