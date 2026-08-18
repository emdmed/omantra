.PHONY: check test lint hooks install

# The whole gate. Run before committing — `make hooks` makes that automatic,
# and .github/workflows/check.yml runs the same target on every push.
check: lint test

test:
	@bash test/run.sh

# shellcheck is the only linter here worth the trouble: this repo is mostly
# bash, and the failure modes are quoting and `set -e` interactions rather than
# style. Not fatal when it isn't installed — it is a developer tool, not a
# runtime dependency.
lint:
	@if command -v shellcheck >/dev/null; then \
	  shellcheck -x bin/* install.sh uninstall.sh lib/*.sh test/*.sh hooks/pre-commit \
	    && echo "shellcheck: clean"; \
	else \
	  echo "shellcheck not installed — skipping (omarchy pkg add shellcheck)"; \
	fi

# Symlinked rather than copied, so the hook in the checkout stays the one that
# runs. Not automatic on clone — git will not install hooks for you.
hooks:
	@ln -sfn ../../hooks/pre-commit .git/hooks/pre-commit
	@echo "installed .git/hooks/pre-commit -> hooks/pre-commit"

install:
	@./install.sh
