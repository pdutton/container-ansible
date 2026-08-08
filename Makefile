IMAGE    ?= ansible
VARIANTS := alpine-stable alpine-development ubuntu-stable ubuntu-development

# External tools, overridable: `make PODMAN=/usr/local/bin/podman build`
AWK      ?= /usr/bin/awk
PODMAN   ?= /usr/bin/podman

BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_REV    := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)

# STABLE tracks Ansible 13, DEVELOPMENT tracks 14. The smoke test asserts on
# this, so a distro bump fails loudly instead of silently redefining a channel.
major-stable      := 13
major-development := 14

# Only the Ubuntu variants carry the winrm/kerberos/gssapi/selinux stack; the
# smoke test asserts on this too, keyed off the OS half of the variant name.
winrm-alpine  := false
winrm-ubuntu  := true

.DEFAULT_GOAL := help
.PHONY: help build test clean

help:
	@echo "Targets:"
	@echo "  build                 Build all four variants"
	@echo "  test                  Smoke-test all four variants"
	@echo "  clean                 Remove all tagged images built by this repo"
	@$(foreach v,$(VARIANTS),echo "  build-$(v)"; echo "  test-$(v)";)
	@echo
	@echo "Variants: $(VARIANTS)"

build: $(addprefix build-,$(VARIANTS))

test: $(addprefix test-,$(VARIANTS))

build-%: Containerfile.%
	$(PODMAN) build -f Containerfile.$* -t $(IMAGE):$* \
	  --label org.opencontainers.image.created=$(BUILD_DATE) \
	  --label org.opencontainers.image.revision=$(GIT_REV) \
	  .
	@$(MAKE) --no-print-directory version-tag-$*

# Read the bundle version out of the freshly built image and apply it as both a
# label and a tag. Uses ansible-community (the bundle version), not
# `ansible --version` (the core version).
version-tag-%:
	@set -eu; \
	version=$$($(PODMAN) run --rm $(IMAGE):$* ansible-community --version | $(AWK) 'NR==1{print $$NF}'); \
	case "$$version" in \
	  [0-9]*.[0-9]*.[0-9]*) ;; \
	  *) echo "ERROR: could not read bundle version from $(IMAGE):$* (got '$$version')" >&2; exit 1 ;; \
	esac; \
	os="$(word 1,$(subst -, ,$*))"; \
	printf 'FROM %s:%s\nLABEL org.opencontainers.image.version="%s"\n' "$(IMAGE)" "$*" "$$version" \
	  | $(PODMAN) build -f - -t "$(IMAGE):$$os-$$version" -t "$(IMAGE):$*" .; \
	echo "Tagged $(IMAGE):$$os-$$version"

test-%: build-%
	$(PODMAN) run --rm -v ./test:/apps:ro,z $(IMAGE):$* \
	  ansible-playbook -i localhost, -c local smoke.yml \
	  -e expect_major=$(major-$(word 2,$(subst -, ,$*))) \
	  -e expect_winrm=$(winrm-$(word 1,$(subst -, ,$*)))

# Removes the two tags this repo applies per variant (<os>-<channel> and
# <os>-<version>). It does NOT reclaim the orphaned <none> base layers each
# version-tag-% build leaves behind -- podman rmi on a tag doesn't cascade to
# the image it was derived from. Run `podman image prune` periodically to
# clear those; this target intentionally does not do that itself, since a
# blanket prune would delete images this repo never built.
clean:
	@ids=$$($(PODMAN) images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -n "$$ids" ]; then $(PODMAN) rmi -f $$ids; else echo "nothing to clean"; fi
