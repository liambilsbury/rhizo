# settings
.DEFAULT_GOAL := payload
.DELETE_ON_ERROR:
.NOTPARALLEL:
SHELL := /bin/bash

# host or container
IN_ENV := tools/build/env/run.sh
HOST_GOALS := help lint test setup container shell inputs inputs-a17 kernel-inputs kernel-deb kernel-arch
BUILD_GOALS := $(filter-out $(HOST_GOALS) env-%,$(or $(MAKECMDGOALS),payload))
ON_HOST := $(if $(wildcard /run/.containerenv /.dockerenv),,$(wildcard $(IN_ENV)))

ifneq ($(and $(ON_HOST),$(BUILD_GOALS)),)
.PHONY: $(BUILD_GOALS)
$(firstword $(BUILD_GOALS)):
	@$(IN_ENV) $(MAKE) $(if $(findstring n,$(firstword -$(MAKEFLAGS))),-n) $(BUILD_GOALS) $(MAKEOVERRIDES)
$(filter-out $(firstword $(BUILD_GOALS)),$(BUILD_GOALS)): $(firstword $(BUILD_GOALS))
	@:
else
# build rules
include tools/build/rules.mk

# changed stamps
CHANGED := $(shell python3 tools/build/stamps.py changed)
ifneq ($(.SHELLSTATUS),0)
$(error tools/build/stamps.py changed failed -- run it by hand to see why)
endif
$(CHANGED): FORCE

# package version
DEB_VERSION := $(shell awk -F'[()]' 'NR==1{print $$2}' debian/changelog)
DEB := var/debs/rhizo_$(DEB_VERSION)_amd64.deb
ifneq ($(filter deb arch,$(MAKECMDGOALS)),)
ifneq ($(shell python3 tools/build/stamps.py deb-require $(DEB) >/dev/null 2>&1; echo $$?),0)
$(DEB).inputs: FORCE
endif
endif

# payload and packages
.PHONY: payload all deb arch FORCE
payload: $(PAYLOAD_STAMPS)
all: $(ALL_STAMPS)
deb: $(DEB).inputs
$(DEB).inputs: $(PAYLOAD_STAMPS)
	tools/build/packaging/deb/debs.sh
arch: deb
	tools/build/packaging/arch/arch-payload.sh $(DEB) var/arch-pkg
# GSI
.PHONY: gsi
gsi:
	tools/build/image/gsi.sh --release $(or $(RELEASE),a16) --variant $(or $(VARIANT),user) --revision $(or $(REVISION),1) $(if $(RELEASE_CONFIG),--release-config $(RELEASE_CONFIG))
FORCE:

# inputs
.rhizo-inputs.tsv:
	@echo "no .rhizo-inputs.tsv -- run make inputs first (it runs tools/fetch/build-inputs.sh)" >&2; exit 1

tools/build/rules.mk: tools/build/artifacts.tsv tools/build/rules.py
	@python3 tools/build/rules.py
endif

# help
.PHONY: help
help:
	@python3 tools/build/rules.py help

# test
TEST_ARGS = $(if $(filter 1,$(V)),-v)
.PHONY: test
ifeq ($(wildcard /run/.containerenv /.dockerenv),)
test:
	@python3 test/checks/run-tests.py --container $(TEST_ARGS)
else
test:
	@python3 test/checks/run-tests.py $(TEST_ARGS)
endif

# lint
SHELL_SCRIPTS = git ls-files | while IFS= read -r f; do [[ -f "$$f" ]] || continue; \
	  case "$$f" in *.sh|*.bash) echo "$$f"; continue ;; esac; \
	  IFS= read -r line < "$$f" && [[ "$$line" =~ ^\#!.*[/\ ](ba|da)?sh([[:space:]]|$$) ]] && echo "$$f"; \
	done
.PHONY: lint
lint:
	@rc=0; \
	git ls-files '*.py' | while IFS= read -r f; do [[ -f "$$f" ]] && echo "$$f"; done \
	  | xargs -r -d '\n' python3 -m pyflakes || rc=1; \
	$(SHELL_SCRIPTS) | xargs -r -d '\n' -n 16 -P "$$(nproc)" shellcheck -S warning || rc=1; \
	kernel/tools/checkpatch-patches.sh || rc=1; \
	exit $$rc

# build container
.PHONY: setup container shell inputs inputs-a17
setup:
	tools/build/env/setup-host.sh
	$(IN_ENV) --build-image
container:
	$(IN_ENV) --build-image
shell:
	$(IN_ENV) bash
inputs:
	@if [[ "$(ACCEPT_ANDROID_SDK_LICENSE)" != 1 ]]; then \
	  echo "make inputs fetches Google's Android SDK build tools, under https://developer.android.com/studio/terms" >&2; \
	  echo "  read those terms, then run: make inputs ACCEPT_ANDROID_SDK_LICENSE=1" >&2; exit 1; fi
	$(IN_ENV) tools/fetch/build-inputs.sh --accept-android-sdk-license --sync-aosp
inputs-a17:
	$(IN_ENV) tools/fetch/aosp-a17.sh --sync
env-%:
	$(IN_ENV) make $* $(MAKEOVERRIDES)

# kernel
.PHONY: kernel-inputs kernel-deb kernel-arch
kernel-inputs:
	$(IN_ENV) kernel/tools/fetch-inputs.sh
kernel-deb:
	kernel/packaging/build-ubuntu-in-container.sh var/kernel/ubuntu
kernel-arch:
	kernel/packaging/build-cachyos-in-container.sh var/kernel/cachyos
