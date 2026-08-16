.PHONY: check test lint install

# The whole gate. Run before committing.
check: lint test

test:
	@bash test/run.sh

# shellcheck is the only linter here worth the trouble: this repo is mostly
# bash, and the failure modes are quoting and `set -e` interactions rather than
# style. Not fatal when it isn't installed — it is a developer tool, not a
# runtime dependency.
lint:
	@if command -v shellcheck >/dev/null; then \
	  shellcheck -x bin/omantra bin/omantra-transcribe bin/omantra-supertap \
	    install.sh lib/*.sh test/*.sh && echo "shellcheck: clean"; \
	else \
	  echo "shellcheck not installed — skipping (omarchy pkg add shellcheck)"; \
	fi

install:
	@./install.sh
