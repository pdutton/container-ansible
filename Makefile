IMAGE    ?= ansible
VARIANTS := alpine-stable alpine-development ubuntu-stable ubuntu-development

# External tools, overridable: `make PODMAN=/usr/local/bin/podman build`
AWK      ?= /usr/bin/awk
PODMAN   ?= /usr/bin/podman

# Registry the push targets publish to. Override to retarget:
# `make push REGISTRY=ghcr.io/pdutton`
REGISTRY ?= docker.io/pdutton

# The one variant that also carries the `latest` tag. Ubuntu is the variant
# with no capability gaps (WinRM/Kerberos/SELinux work only there) and stable
# is the conservative channel, so an unqualified pull lands on the image least
# likely to fail in a way the puller cannot diagnose.
LATEST_VARIANT := ubuntu-stable

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

# Shell snippet, expanded inside a recipe. Given $version already set by the
# recipe and $* set by the pattern rule, it sets $tags to the full tag list for
# that variant. tag-% and push-% both expand it, so the tag scheme is defined
# in exactly one place.
#
# Two deliberate details:
#  * Written as one logical line. Backslash continuations in a variable
#    assignment collapse to spaces, so expanding this inside a recipe cannot
#    introduce a newline into the shell command.
#  * `if ... fi` rather than `[ ... ] && ...`. Under `set -e` a false test in
#    the latter form is a non-zero exit status for the whole line, which aborts
#    the recipe instead of skipping the tag.
#
# The major comes from the detected version, never from major-stable /
# major-development above -- those feed the smoke test's expect_major assertion
# and must stay able to disagree with reality, which is what makes a distro
# bump fail loudly.
TAG_SET_SH = os="$(word 1,$(subst -, ,$*))"; \
             channel="$(word 2,$(subst -, ,$*))"; \
             major="$${version%%.*}"; \
             tags="$* $$os-$$major $$os-$$version"; \
             if [ "$$channel" = stable ]; then tags="$$tags $$os"; fi; \
             if [ "$*" = "$(LATEST_VARIANT)" ]; then tags="$$tags latest"; fi

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
	@$(MAKE) --no-print-directory tag-$*

# Read the bundle version out of the freshly built image, stamp it on as a
# label, and apply the full tag set. Uses ansible-community (the bundle
# version), not `ansible --version` (the core version).
tag-%:
	@set -eu; \
	version=$$($(PODMAN) run --rm $(IMAGE):$* ansible-community --version | $(AWK) 'NR==1{print $$NF}'); \
	case "$$version" in \
	  [0-9]*.[0-9]*.[0-9]*) ;; \
	  *) echo "ERROR: could not read bundle version from $(IMAGE):$* (got '$$version')" >&2; exit 1 ;; \
	esac; \
	$(TAG_SET_SH); \
	printf 'FROM %s:%s\nLABEL org.opencontainers.image.version="%s"\n' "$(IMAGE)" "$*" "$$version" \
	  | $(PODMAN) build -f - -t "$(IMAGE):$*" .; \
	for t in $$tags; do $(PODMAN) tag "$(IMAGE):$*" "$(IMAGE):$$t"; done; \
	echo "Tagged $(IMAGE): $$tags"

test-%: build-%
	$(PODMAN) run --rm -v ./test:/apps:ro,z $(IMAGE):$* \
	  ansible-playbook -i localhost, -c local smoke.yml \
	  -e expect_major=$(major-$(word 2,$(subst -, ,$*))) \
	  -e expect_winrm=$(winrm-$(word 1,$(subst -, ,$*)))

# Removes every tag this repo applies -- three to five per variant:
# <os>-<channel>, <os>-<major>, <os>-<version>, plus <os> on the stable
# variants and `latest` on $(LATEST_VARIANT). Push never creates a
# registry-qualified local tag, so the localhost-anchored match below still
# covers the complete set. It does NOT reclaim the orphaned <none> base layers each
# version-tag-% build leaves behind -- podman rmi on a tag doesn't cascade to
# the image it was derived from. Run `podman image prune` periodically to
# clear those; this target intentionally does not do that itself, since a
# blanket prune would delete images this repo never built.
clean:
	@ids=$$($(PODMAN) images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -n "$$ids" ]; then $(PODMAN) rmi -f $$ids; else echo "nothing to clean"; fi
