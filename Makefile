IMAGE    ?= ansible
VARIANTS := alpine-stable alpine-development ubuntu-stable ubuntu-development

# External tools, overridable: `make PODMAN=/usr/local/bin/podman build`
AWK      ?= /usr/bin/awk
PODMAN   ?= /usr/bin/podman

# Registry the push targets publish to. Override to retarget:
# `make push REGISTRY=ghcr.io/pdutton`
REGISTRY ?= docker.io/pdutton

# Every local image reference goes through this, never a bare $(IMAGE). A bare
# short name resolves to a non-localhost repo when that is the only match
# (measured on podman 5.8.1), so an unqualified reference on the highest-stakes
# line in this file -- the push source -- would depend on an implicit
# tie-break rather than on the name itself. `=` (recursive), not `:=`, so this
# still tracks an overridden IMAGE.
LOCAL_IMAGE = localhost/$(IMAGE)

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
.PHONY: help build test push clean

help:
	@echo "Targets:"
	@echo "  build                 Build all four variants"
	@echo "  test                  Smoke-test all four variants"
	@echo "  push                  Push all four variants to $(REGISTRY)/$(IMAGE)"
	@echo "  clean                 Remove all tagged images built by this repo"
	@$(foreach v,$(VARIANTS),echo "  build-$(v)"; echo "  test-$(v)"; echo "  push-$(v)";)
	@echo
	@echo "Variants: $(VARIANTS)"

build: $(addprefix build-,$(VARIANTS))

test: $(addprefix test-,$(VARIANTS))

build-%: Containerfile.%
	$(PODMAN) build -f Containerfile.$* -t $(LOCAL_IMAGE):$* \
	  --label org.opencontainers.image.created=$(BUILD_DATE) \
	  --label org.opencontainers.image.revision=$(GIT_REV) \
	  .
	@$(MAKE) --no-print-directory tag-$*

# Read the bundle version out of the freshly built image, stamp it on as a
# label, and apply the full tag set. Uses ansible-community (the bundle
# version), not `ansible --version` (the core version).
tag-%:
	@set -eu; \
	version=$$($(PODMAN) run --rm $(LOCAL_IMAGE):$* ansible-community --version | $(AWK) 'NR==1{print $$NF}'); \
	case "$$version" in \
	  [0-9]*.[0-9]*.[0-9]*) ;; \
	  *) echo "ERROR: could not read bundle version from $(LOCAL_IMAGE):$* (got '$$version')" >&2; exit 1 ;; \
	esac; \
	$(TAG_SET_SH); \
	printf 'FROM %s:%s\nLABEL org.opencontainers.image.version="%s"\n' "$(LOCAL_IMAGE)" "$*" "$$version" \
	  | $(PODMAN) build -f - -t "$(LOCAL_IMAGE):$*" .; \
	for t in $$tags; do $(PODMAN) tag "$(LOCAL_IMAGE):$*" "$(LOCAL_IMAGE):$$t"; done; \
	echo "Tagged $(LOCAL_IMAGE): $$tags"

test-%: build-%
	$(PODMAN) run --rm -v ./test:/apps:ro,z $(LOCAL_IMAGE):$* \
	  ansible-playbook -i localhost, -c local smoke.yml \
	  -e expect_major=$(major-$(word 2,$(subst -, ,$*))) \
	  -e expect_winrm=$(winrm-$(word 1,$(subst -, ,$*)))

# Mirror every tag in the set to $(REGISTRY). Depends on test-%, so a
# smoke-test failure blocks the publish and a broken image cannot reach the
# registry through this path.
#
# The version is read back off the label tag-% applied rather than by running
# the container again -- an inspect, not a container start.
#
# The push source is explicitly localhost-qualified ($(LOCAL_IMAGE)), not a
# bare short name -- a bare name can resolve to a non-localhost repo when
# that's the only match, which would make this, the highest-stakes line in
# the repo, depend on an implicit tie-break. podman push SOURCE DESTINATION
# never creates a registry-qualified local tag, so `clean` keeps matching the
# complete set.
#
# Not atomic: a failure partway through the loop leaves the earlier tags in
# this run already published and the remaining ones stale. The failure is
# loud (non-zero exit), which is the requirement, but it is not a rollback.
push-%: test-%
	@set -eu; \
	version=$$($(PODMAN) image inspect \
	  --format '{{index .Labels "org.opencontainers.image.version"}}' $(LOCAL_IMAGE):$*); \
	case "$$version" in \
	  [0-9]*.[0-9]*.[0-9]*) ;; \
	  *) echo "ERROR: $(LOCAL_IMAGE):$* carries no usable org.opencontainers.image.version label (got '$$version')" >&2; exit 1 ;; \
	esac; \
	$(TAG_SET_SH); \
	for t in $$tags; do \
	  echo "Pushing $(REGISTRY)/$(IMAGE):$$t"; \
	  $(PODMAN) push "$(LOCAL_IMAGE):$$t" "$(REGISTRY)/$(IMAGE):$$t"; \
	done

push: $(addprefix push-,$(VARIANTS))

# Removes every tag this repo applies -- three to five per variant:
# <os>-<channel>, <os>-<major>, <os>-<version>, plus <os> on the stable
# variants and `latest` on $(LATEST_VARIANT). Push never creates a
# registry-qualified local tag, so the localhost-anchored match below still
# covers the complete set. It does NOT reclaim the orphaned <none> base layers each
# tag-% build leaves behind -- podman rmi on a tag doesn't cascade to
# the image it was derived from. Run `podman image prune` periodically to
# clear those; this target intentionally does not do that itself, since a
# blanket prune would delete images this repo never built.
clean:
	@ids=$$($(PODMAN) images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -n "$$ids" ]; then $(PODMAN) rmi -f $$ids; else echo "nothing to clean"; fi
