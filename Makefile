# Shinux Repository -- build, sign and publish rpm + deb packages.
SHELL := /bin/bash
.DEFAULT_GOAL := help

help:  ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

key:  ## create (or re-export) the repository signing key
	@scripts/gpg-setup.sh

icons:  ## regenerate the site icons in docs/ (never hand-edit the PNGs)
	@scripts/make-icons.py

build:  ## build every package into build/out
	@scripts/build.sh

publish: build  ## build, sign, and regenerate all repository metadata in docs/
	@scripts/make-repo.sh

bump:  ## bump a version: make bump PKG=hello-shinux LEVEL=patch
	@scripts/bump.sh $(PKG) $(or $(LEVEL),release)

prune:  ## keep only the newest KEEP=3 versions of each package
	@scripts/prune.sh $(or $(KEEP),3)

notes:  ## rewrite the pool release's description from what is attached to it
	@scripts/pool-notes.sh

serve:  ## serve docs/ on http://127.0.0.1:8099 for manual testing
	@scripts/serve.sh

test: test-fedora test-debian test-arch  ## end-to-end install test on all three families

test-fedora:  ## install from a throwaway local repo inside a Fedora container
	@scripts/test-install.sh fedora

test-debian:  ## install from a throwaway local repo inside a Debian container
	@scripts/test-install.sh debian

test-arch:  ## install from a throwaway local repo inside an Arch container
	scripts/test-install.sh arch

clean:  ## remove build artefacts (docs/ is left alone)
	@rm -rf build
	@echo "cleaned build/"

.PHONY: help key icons build publish bump prune notes serve test test-fedora test-debian test-arch clean
