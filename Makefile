IMAGE    ?= ansible
VARIANTS := alpine-stable alpine-development ubuntu-stable ubuntu-development

BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_REV    := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)

# STABLE tracks Ansible 13, DEVELOPMENT tracks 14. The smoke test asserts on
# this, so a distro bump fails loudly instead of silently redefining a channel.
major-stable      := 13
major-development := 14

.DEFAULT_GOAL := help
# NOTE: deliberately NOT listing the per-variant build-%/test-% names here.
# GNU Make 4.4.1 has a quirk where explicitly listing a pattern-rule target's
# expanded name in .PHONY causes that name to resolve to a phony stub with no
# prerequisites the first time it is requested, permanently short-circuiting
# the pattern-rule search ("make: Nothing to be done for 'test-alpine-stable'"
# instead of running the recipe). Verified with a minimal repro. These targets
# never correspond to real files, so they are rebuilt unconditionally with or
# without the .PHONY marking - omitting them here changes nothing functional.
.PHONY: help build test clean

help:
	@echo "Targets:"
	@echo "  build                 Build all four variants"
	@echo "  test                  Smoke-test all four variants"
	@echo "  clean                 Remove all built images"
	@$(foreach v,$(VARIANTS),echo "  build-$(v)"; echo "  test-$(v)";)
	@echo
	@echo "Variants: $(VARIANTS)"

build: $(addprefix build-,$(VARIANTS))

test: $(addprefix test-,$(VARIANTS))

build-%: Containerfile.%
	podman build -f Containerfile.$* -t $(IMAGE):$* \
	  --label org.opencontainers.image.created=$(BUILD_DATE) \
	  --label org.opencontainers.image.revision=$(GIT_REV) \
	  .
	@$(MAKE) --no-print-directory version-tag-$*

# Read the bundle version out of the freshly built image and apply it as both a
# label and a tag. Uses ansible-community (the bundle version), not
# `ansible --version` (the core version).
version-tag-%:
	@set -eu; \
	version=$$(podman run --rm $(IMAGE):$* ansible-community --version | awk '{print $$NF}'); \
	case "$$version" in \
	  [0-9]*.[0-9]*.[0-9]*) ;; \
	  *) echo "ERROR: could not read bundle version from $(IMAGE):$* (got '$$version')" >&2; exit 1 ;; \
	esac; \
	os="$(word 1,$(subst -, ,$*))"; \
	printf 'FROM %s:%s\nLABEL org.opencontainers.image.version="%s"\n' "$(IMAGE)" "$*" "$$version" \
	  | podman build -f - -t "$(IMAGE):$$os-$$version" -t "$(IMAGE):$*" .; \
	echo "Tagged $(IMAGE):$$os-$$version"

test-%: build-%
	podman run --rm -v ./test:/apps:ro $(IMAGE):$* \
	  ansible-playbook -i localhost, -c local smoke.yml \
	  -e expect_major=$(major-$(word 2,$(subst -, ,$*)))

clean:
	@ids=$$(podman images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -n "$$ids" ]; then podman rmi -f $$ids; else echo "nothing to clean"; fi
