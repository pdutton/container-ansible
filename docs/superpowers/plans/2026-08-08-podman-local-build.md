# Phase 1 Local Podman Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build four Ansible container image variants locally with Podman and verify each by running a smoke-test playbook inside it.

**Architecture:** Four explicit Containerfiles (Alpine 3.23 and Ubuntu 26.04, each in a STABLE and a DEVELOPMENT channel) carry static OCI labels and no build args. A Makefile drives builds, injects the dynamic labels, reads the installed Ansible version back out of the freshly built image to apply a version tag, and runs a smoke-test playbook against `localhost` with `-c local`.

**Tech Stack:** Podman 5.x, GNU Make, Alpine `apk`, Ubuntu `apt`, Python `venv` + `pip`, Ansible (community bundle).

## Global Constraints

These apply to **every** task. Values are exact — do not substitute near-equivalents.

- Working directory is the worktree `/home/pdutton/projects/container-ansible/feature/podman-build`. Use `git -C <worktree>` for all git commands.
- Image name is `ansible` (not `container-ansible`). Tags are `<os>-<channel>` and `<os>-<version>`.
- The four variant names, used verbatim as Containerfile suffixes, image tags, and Make target suffixes: `alpine-stable`, `alpine-development`, `ubuntu-stable`, `ubuntu-development`.
- Base images, pinned: `docker.io/library/alpine:3.23` and `docker.io/library/ubuntu:26.04`. Both Alpine variants use 3.23; both Ubuntu variants use 26.04.
- SPDX license identifier in every label block: `GPL-3.0-or-later`.
- Source/URL label value: `https://github.com/pdutton/container-ansible`. Vendor: `pdutton`. Title: `ansible`.
- STABLE = Ansible major **13**, from the OS package manager. DEVELOPMENT = Ansible major **14**, from pip into a venv at `/opt/ansible`.
- Containerfiles contain **no `ARG`** and **no `ENTRYPOINT`**. Every Containerfile ends with `WORKDIR /apps` and a `CMD` of that OS's shell.
- On Alpine the SSH client package is `openssh-client-default`. `openssh-client` is only a *provides* alias and must not be used.
- On Ubuntu, `apt-get install` always uses `--no-install-recommends` plus the explicit package list given in Task 3.
- Commit after every task. Never commit in `primary/`.

---

## File Structure

| File | Responsibility |
|---|---|
| `.dockerignore` | Keep the build context near-empty. No `COPY` happens in Phase 1. |
| `Containerfile.alpine-stable` | Alpine 3.23 + `apk` Ansible 13. |
| `Containerfile.alpine-development` | Alpine 3.23 + pip venv Ansible 14. |
| `Containerfile.ubuntu-stable` | Ubuntu 26.04 + `apt` Ansible 13. |
| `Containerfile.ubuntu-development` | Ubuntu 26.04 + pip venv Ansible 14. |
| `test/smoke.yml` | Single playbook, run inside every variant, asserting on installed capabilities. |
| `Makefile` | Build, version-tag, test, clean, help. The only place dynamic values live. |
| `README.md` | Modify: usage, variant table, capability differences, license election. |

The Containerfiles are deliberately duplicative — the whole point of the four-file layout is that each is readable standalone. Do not factor shared lines into an include.

Task order is dependency order: `.dockerignore` and the smoke playbook exist before anything is built, one Containerfile proves the pattern, the remaining three follow, then the Makefile ties them together, then the README documents the result.

---

### Task 1: Build context hygiene and the smoke-test playbook

**Files:**
- Create: `.dockerignore`
- Create: `test/smoke.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: `test/smoke.yml`, a playbook taking one extra-var `expect_major` (an integer as a string, e.g. `"13"`). Every later task runs it via `ansible-playbook -i localhost, -c local smoke.yml -e expect_major=<N>` with `test/` mounted at `/apps`.

- [ ] **Step 1: Create `.dockerignore`**

Nothing is `COPY`d in Phase 1, so this exists solely to stop Podman from streaming the repo into the build. Podman also honors `.containerignore`; we use `.dockerignore` so the same files work with Docker.

```
.git/
docs/
test/
Makefile
README.md
LICENSE
```

- [ ] **Step 2: Write the smoke-test playbook**

Create `test/smoke.yml`. This is the failing test for every subsequent task — it cannot pass until an image exists to run it in.

Each assertion maps to a package the Containerfiles deliberately install, so a missing dependency fails here rather than in a user's playbook months later. `ansible_version.full` is the *core* version, so the bundle version comes from `ansible-community --version` instead.

```yaml
---
- name: Smoke-test the ansible container image
  hosts: localhost
  gather_facts: false
  vars:
    expect_major: ""

  tasks:
    - name: Require expect_major to be supplied
      ansible.builtin.assert:
        that:
          - expect_major | length > 0
        fail_msg: "Run with -e expect_major=<N>"

    - name: Read the Ansible community bundle version
      ansible.builtin.command: ansible-community --version
      register: community_version
      changed_when: false

    - name: Assert the bundle major matches the channel
      ansible.builtin.assert:
        that:
          - community_version.stdout.split()[-1].split('.')[0] == expect_major
        fail_msg: >-
          Expected Ansible major {{ expect_major }}, got
          '{{ community_version.stdout }}'. The distro may have changed
          which version this channel resolves to.
        success_msg: "Ansible bundle {{ community_version.stdout.split()[-1] }}"

    - name: Assert json_query works (requires jmespath)
      ansible.builtin.assert:
        that:
          - >-
            [{'n': 'a'}, {'n': 'b'}] | community.general.json_query('[].n')
            == ['a', 'b']
        fail_msg: "json_query failed - jmespath is missing"

    - name: Assert password_hash works (requires passlib)
      ansible.builtin.assert:
        that:
          - "'x' | password_hash('sha512', 'abcdefghijklmnop') is match('^\\$6\\$')"
        fail_msg: "password_hash failed - passlib is missing"

    - name: Locate the ssh client
      ansible.builtin.command: which ssh
      register: ssh_path
      changed_when: false
      failed_when: ssh_path.rc != 0

    - name: Create a directory
      ansible.builtin.file:
        path: /tmp/smoke
        state: directory
        mode: "0755"

    - name: Copy content into it
      ansible.builtin.copy:
        content: "ok\n"
        dest: /tmp/smoke/result.txt
        mode: "0644"

    - name: Read it back
      ansible.builtin.slurp:
        src: /tmp/smoke/result.txt
      register: readback

    - name: Assert the file round-tripped
      ansible.builtin.assert:
        that:
          - (readback.content | b64decode) == "ok\n"
        fail_msg: "copy/slurp round-trip failed"
```

- [ ] **Step 3: Verify the YAML parses**

The playbook cannot run yet — no image exists — but a syntax error should not wait for Task 2 to surface.

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('test/smoke.yml')); print('YAML OK')"
```
Expected: `YAML OK`

- [ ] **Step 4: Commit**

```bash
git add .dockerignore test/smoke.yml
git commit -m "Add build context ignore rules and smoke-test playbook"
```

---

### Task 2: `alpine-stable` — the pattern-setting variant

**Files:**
- Create: `Containerfile.alpine-stable`

**Interfaces:**
- Consumes: `test/smoke.yml` from Task 1.
- Produces: the label block, `WORKDIR`, and `CMD` conventions that Tasks 3–5 copy verbatim. Builds to image tag `ansible:alpine-stable`.

Alpine's `ansible` package depends only on `python3` and `ansible-core` — **it pulls no SSH client** — so `openssh-client-default` is a functional requirement, not a nicety.

- [ ] **Step 1: Run the smoke test to verify it fails**

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:alpine-stable \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=13
```
Expected: FAIL — the image does not exist yet.

- [ ] **Step 2: Write the Containerfile**

```dockerfile
FROM docker.io/library/alpine:3.23

LABEL org.opencontainers.image.title="ansible" \
      org.opencontainers.image.description="Ansible 13 (stable) on Alpine 3.23, from distro packages" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.23"

# Alpine's ansible package pulls no SSH client, so openssh-client-default is
# required. Note "openssh-client" is only a provides alias and will not resolve.
RUN apk add --no-cache \
      ansible \
      openssh-client-default \
      sshpass \
      py3-jmespath \
      py3-passlib \
      py3-xmltodict \
      py3-requests \
      py3-argcomplete

WORKDIR /apps
CMD ["/bin/sh"]
```

- [ ] **Step 3: Build it**

Run:
```bash
podman build -f Containerfile.alpine-stable -t ansible:alpine-stable .
```
Expected: build succeeds.

- [ ] **Step 4: Run the smoke test to verify it passes**

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:alpine-stable \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=13
```
Expected: PASS, with the bundle-version task reporting `Ansible bundle 13.0.0`.

If the `json_query` assertion fails because `community.general` is absent, the distro `ansible` package is not the full bundle — stop and report, do not paper over it by removing the assertion.

- [ ] **Step 5: Commit**

```bash
git add Containerfile.alpine-stable
git commit -m "Add alpine-stable image: Ansible 13 from apk on Alpine 3.23"
```

---

### Task 3: `ubuntu-stable`

**Files:**
- Create: `Containerfile.ubuntu-stable`

**Interfaces:**
- Consumes: the conventions from Task 2.
- Produces: image tag `ansible:ubuntu-stable`.

The explicit package list replaces apt's recommends tree. Measured on Ubuntu 26.04: with recommends 715 MB, with this explicit list 664 MB, with bare `--no-install-recommends` 651 MB. The list keeps every functional package while shedding ~51 MB of X11 (pulled in only because `openssh-client` recommends `xauth` for X forwarding), Sphinx docs JS, and Babel locale data. Dropping recommends bare saves just 13 MB more but breaks `json_query`, `password_hash`, the `xml` module, and all Windows/WinRM and Kerberos connectivity.

- [ ] **Step 1: Run the smoke test to verify it fails**

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:ubuntu-stable \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=13
```
Expected: FAIL — the image does not exist yet.

- [ ] **Step 2: Write the Containerfile**

```dockerfile
FROM docker.io/library/ubuntu:26.04

LABEL org.opencontainers.image.title="ansible" \
      org.opencontainers.image.description="Ansible 13 (stable) on Ubuntu 26.04, from distro packages" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:26.04"

# --no-install-recommends plus an explicit list: keeps the functional packages
# apt would recommend, drops X11/Sphinx/Babel ballast a container never uses.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ansible \
      openssh-client \
      sshpass \
      python3-jmespath \
      python3-passlib \
      python3-xmltodict \
      python3-selinux \
      python3-winrm \
      python3-pyspnego \
      python3-requests-ntlm \
      python3-kerberos \
      python3-gssapi \
      python3-requests \
      python3-argcomplete \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /apps
CMD ["/bin/bash"]
```

- [ ] **Step 3: Build it**

Run:
```bash
podman build -f Containerfile.ubuntu-stable -t ansible:ubuntu-stable .
```
Expected: build succeeds.

- [ ] **Step 4: Run the smoke test to verify it passes**

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:ubuntu-stable \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=13
```
Expected: PASS, reporting `Ansible bundle 13.1.0`.

- [ ] **Step 5: Check the size landed where expected**

Run:
```bash
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep ubuntu-stable
```
Expected: roughly 664 MB. A number near 715 MB means `--no-install-recommends` was dropped; investigate rather than accept.

- [ ] **Step 6: Commit**

```bash
git add Containerfile.ubuntu-stable
git commit -m "Add ubuntu-stable image: Ansible 13 from apt on Ubuntu 26.04"
```

---

### Task 4: `alpine-development`

**Files:**
- Create: `Containerfile.alpine-development`

**Interfaces:**
- Consumes: the conventions from Task 2.
- Produces: image tag `ansible:alpine-development`, and establishes the venv layout (`/opt/ansible`, `PATH` prepended) that Task 5 reuses.

Alpine 3.23's system Python (3.12) is PEP 668 externally-managed, so pip cannot install into system site-packages. A venv is used rather than `--break-system-packages`: it leaves the distro Python untouched — which matters for the "use as a base image" case — and the Ansible install cannot be clobbered by a later `apk` operation.

**Known risk:** `pip install ansible` on musl may need to compile `cryptography` if no `musllinux` wheel is published for the resolved version. Step 3 handles this. Do not skip it.

- [ ] **Step 1: Run the smoke test to verify it fails**

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:alpine-development \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=14
```
Expected: FAIL — the image does not exist yet.

- [ ] **Step 2: Write the Containerfile**

Start without build dependencies; Step 3 adds them only if the build proves they are needed. `py3-jmespath` and friends are installed via `apk` for the runtime Python but the venv needs its own copies, so they are pip-installed alongside Ansible.

```dockerfile
FROM docker.io/library/alpine:3.23

LABEL org.opencontainers.image.title="ansible" \
      org.opencontainers.image.description="Ansible 14 (development) on Alpine 3.23, from pip" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.23"

# System Python is PEP 668 externally-managed, so Ansible goes in a venv.
RUN apk add --no-cache \
      python3 \
      py3-pip \
      openssh-client-default \
      sshpass \
 && python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir \
      "ansible>=14,<15" \
      jmespath \
      passlib \
      xmltodict \
      requests \
      argcomplete

ENV PATH="/opt/ansible/bin:$PATH"

WORKDIR /apps
CMD ["/bin/sh"]
```

- [ ] **Step 3: Build it, adding build dependencies only if required**

Run:
```bash
podman build -f Containerfile.alpine-development -t ansible:alpine-development .
```

If it succeeds, continue to Step 4 and leave the Containerfile as written.

If it fails with a compiler or `Rust`/`cargo` error while building `cryptography` (or any other wheel), edit the `RUN` block to install build dependencies as a virtual group and delete them in the same layer, so they never reach the final image:

```dockerfile
RUN apk add --no-cache \
      python3 \
      py3-pip \
      openssh-client-default \
      sshpass \
 && apk add --no-cache --virtual .build-deps \
      gcc \
      musl-dev \
      python3-dev \
      libffi-dev \
      openssl-dev \
      cargo \
 && python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir \
      "ansible>=14,<15" \
      jmespath \
      passlib \
      xmltodict \
      requests \
      argcomplete \
 && apk del .build-deps
```

Then rebuild with the same command. Expected: build succeeds.

- [ ] **Step 4: Run the smoke test to verify it passes**

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:alpine-development \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=14
```
Expected: PASS, reporting a `14.x.y` bundle version.

- [ ] **Step 5: Verify no build toolchain leaked into the image**

Only meaningful if Step 3 needed the virtual group, but harmless either way.

Run:
```bash
podman run --rm ansible:alpine-development sh -c 'which gcc cargo || echo "no build tools present"'
```
Expected: `no build tools present`

- [ ] **Step 6: Commit**

```bash
git add Containerfile.alpine-development
git commit -m "Add alpine-development image: Ansible 14 from pip venv on Alpine 3.23"
```

---

### Task 5: `ubuntu-development`

**Files:**
- Create: `Containerfile.ubuntu-development`

**Interfaces:**
- Consumes: the venv layout from Task 4.
- Produces: image tag `ansible:ubuntu-development`. This is the final variant; after this task all four exist.

Ubuntu 26.04's system Python (3.14) is PEP 668 externally-managed, same as Alpine. Ubuntu ships no Ansible 14 in any suite — 26.10 still carries 13.1.0 — so pip is required here regardless of which Ubuntu release is chosen. `python3-venv` must be installed explicitly; Ubuntu splits it out of the base `python3` package.

- [ ] **Step 1: Run the smoke test to verify it fails**

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:ubuntu-development \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=14
```
Expected: FAIL — the image does not exist yet.

- [ ] **Step 2: Write the Containerfile**

```dockerfile
FROM docker.io/library/ubuntu:26.04

LABEL org.opencontainers.image.title="ansible" \
      org.opencontainers.image.description="Ansible 14 (development) on Ubuntu 26.04, from pip" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:26.04"

# System Python is PEP 668 externally-managed, so Ansible goes in a venv.
# Ubuntu ships no Ansible 14 in any suite, so pip is required here.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      python3 \
      python3-pip \
      python3-venv \
      openssh-client \
      sshpass \
 && python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir \
      "ansible>=14,<15" \
      jmespath \
      passlib \
      xmltodict \
      requests \
      argcomplete \
 && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/ansible/bin:$PATH"

WORKDIR /apps
CMD ["/bin/bash"]
```

- [ ] **Step 3: Build it**

Run:
```bash
podman build -f Containerfile.ubuntu-development -t ansible:ubuntu-development .
```

If it fails building a wheel from source, add `build-essential`, `python3-dev`, `libffi-dev` and `libssl-dev` to the `apt-get install` list, and append `&& apt-get purge -y build-essential python3-dev libffi-dev libssl-dev && apt-get autoremove -y` before the `rm -rf` so they do not reach the final image. Then rebuild.

Expected: build succeeds.

- [ ] **Step 4: Run the smoke test to verify it passes**

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:ubuntu-development \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=14
```
Expected: PASS, reporting a `14.x.y` bundle version.

- [ ] **Step 5: Commit**

```bash
git add Containerfile.ubuntu-development
git commit -m "Add ubuntu-development image: Ansible 14 from pip venv on Ubuntu 26.04"
```

---

### Task 6: Makefile

**Files:**
- Create: `Makefile`

**Interfaces:**
- Consumes: all four Containerfiles and `test/smoke.yml`.
- Produces: targets `help` (default), `build`, `test`, `clean`, and per-variant `build-<variant>` / `test-<variant>`. Also produces the second tag `ansible:<os>-<version>` for each variant.

Two details that are easy to get wrong:

`ansible-community --version` prints `Ansible community version 13.1.0` — the **bundle** version, and the only value that is portable across apk, apt and pip. `ansible --version` prints `ansible [core 2.20.1]`, a different number that must not be used for tags.

Podman cannot add a label to an existing image in place, so the version label and version tag are applied by a one-line `FROM`+`LABEL` build. This costs one empty layer. The alternative — a hand-maintained version per variant — was rejected as guaranteed to go stale.

- [ ] **Step 1: Write the Makefile**

```make
IMAGE    ?= ansible
VARIANTS := alpine-stable alpine-development ubuntu-stable ubuntu-development

BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_REV    := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)

# STABLE tracks Ansible 13, DEVELOPMENT tracks 14. The smoke test asserts on
# this, so a distro bump fails loudly instead of silently redefining a channel.
major-stable      := 13
major-development := 14

.DEFAULT_GOAL := help
.PHONY: help build test clean $(addprefix build-,$(VARIANTS)) $(addprefix test-,$(VARIANTS))

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
```

Two things that will bite if changed: recipe lines must be indented with **tabs**, not spaces, and `$(word 1,$(subst -, ,$*))` is evaluated by make (not the shell) to strip the channel off the stem — `alpine-stable` becomes `alpine`. Writing that as a shell parameter expansion instead does not work, because the stem is a literal, not a shell variable.

- [ ] **Step 2: Verify `make help` works and is the default**

Run:
```bash
make
```
Expected: the target list prints; nothing builds.

- [ ] **Step 3: Verify a single variant builds, tags, and tests**

Run:
```bash
make test-alpine-stable
```
Expected: builds, prints `Tagged ansible:alpine-13.0.0`, then the smoke test passes.

- [ ] **Step 4: Verify the version tag and labels landed**

Run:
```bash
podman images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost/ansible' | sort
podman inspect ansible:alpine-stable \
  --format '{{json .Labels}}' | python3 -m json.tool
```
Expected: both `ansible:alpine-stable` and `ansible:alpine-13.0.0` are listed; the labels include `org.opencontainers.image.version`, `.created`, `.revision`, and `.licenses` = `GPL-3.0-or-later`.

- [ ] **Step 5: Verify the channel guard actually fails**

Confirm the assertion is real rather than decorative, by asking a stable image to claim it is 14.

Run:
```bash
podman run --rm -v ./test:/apps:ro ansible:alpine-stable \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=14
```
Expected: FAIL, with the "Expected Ansible major 14" message. If this passes, the assertion is broken — fix it before continuing.

- [ ] **Step 6: Build and test everything**

Run:
```bash
make clean && make test
```
Expected: all four variants build and pass. This is the Phase 1 acceptance check.

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "Add Makefile driving builds, version tagging, and smoke tests"
```

---

### Task 7: README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the working images and Make targets from Tasks 2–6.
- Produces: nothing consumed by later tasks. This is the last task.

The existing README describes an aspirational tag scheme (`alpine-13.8.0`, `ubuntu-14`, `latest`) that Phase 1 does not implement, and shows `docker run ... alpine/ansible` examples pointing at a third-party image. Both need to match what now exists.

- [ ] **Step 1: Update the README**

Rewrite the usage and tags sections so they describe the four real variants. Required content:

- Replace the `docker run ... alpine/ansible` alias examples with `podman run`
  against `localhost/ansible:alpine-stable`, keeping the `-v ~/.ssh:/root/.ssh`,
  `-v $(pwd):/apps` and `-w /apps` flags from the originals.
- A variant table: `alpine-stable` (Alpine 3.23, Ansible 13, apk),
  `alpine-development` (Alpine 3.23, Ansible 14, pip venv),
  `ubuntu-stable` (Ubuntu 26.04, Ansible 13, apt),
  `ubuntu-development` (Ubuntu 26.04, Ansible 14, pip venv).
- A "Building locally" section: `make build`, `make test`, `make build-alpine-stable`, `make clean`.
- Explain the two tags per variant — the stable `<os>-<channel>` name and the
  `<os>-<version>` name derived from the installed bundle version.
- A **Capability differences** section stating plainly that Alpine images do
  **not** support Windows/WinRM or Kerberos targets, because Alpine has no
  packages for `winrm`, `pyspnego`, `requests-ntlm`, `kerberos`, `gssapi` or
  `selinux`. `json_query` and `password_hash` work on all four.
- A **License** section stating the project is GPL-3.0-or-later. This matters:
  `LICENSE` holds the bare GPLv3 text with no "or later" election, so the README
  is what makes the `GPL-3.0-or-later` label in the images accurate.
- Move the unimplemented tag scheme (`latest`, older Ansible majors) and the
  multi-arch note under a "Planned" heading so they are not read as current.

- [ ] **Step 2: Verify every command in the README actually runs**

Copy each command out of the README and run it. Do not eyeball this — a README
command that does not run is the most common defect in this kind of change.

Run:
```bash
make build-alpine-stable
podman run --rm -v ~/.ssh:/root/.ssh -v $(pwd):/apps -w /apps \
  localhost/ansible:alpine-stable ansible --version
podman run --rm localhost/ansible:alpine-stable ansible-community --version
```
Expected: each prints version output without error.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document the four image variants, local build workflow, and license"
```

---

## Acceptance

Phase 1 is done when `make clean && make test` builds all four images from
scratch and every smoke test passes, and `podman images` shows eight tags — a
`<os>-<channel>` and an `<os>-<version>` for each variant.
