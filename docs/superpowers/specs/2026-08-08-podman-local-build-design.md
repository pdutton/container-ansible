# Phase 1: Local Container Image Build with Podman

**Date:** 2026-08-08
**Status:** Approved

## Goal

Build four Ansible container image variants locally with Podman, and verify each
one by running it. Nothing in this phase publishes images, builds multi-arch
manifests, or runs in CI.

## Variant Matrix

Two operating systems, each with two Ansible channels:

| Variant | Base image | Install method | Ansible |
|---|---|---|---|
| `alpine-stable` | `alpine:3.23` | `apk add ansible` | 13.0.0 |
| `alpine-development` | `alpine:3.23` | pip into a venv | 14.x |
| `ubuntu-stable` | `ubuntu:26.04` | `apt-get install ansible` | 13.1.0 |
| `ubuntu-development` | `ubuntu:26.04` | pip into a venv | 14.x |

`STABLE` means the current stable Ansible major (13); `DEVELOPMENT` means the
next major (14). Both shift over time; the smoke test asserts on the expected
major so a drift fails loudly rather than silently redefining a channel.

### Why the OS is pinned per variant

Distro packages are preferred wherever they supply the wanted Ansible major.
Surveying the archives on 2026-08-08:

| Ansible major | Alpine | Ubuntu |
|---|---|---|
| 8 | 3.19 | — |
| 9 | 3.20 | 24.04 |
| 11 | 3.21, 3.22 | 25.04 |
| 13 | **3.23** | **26.04 LTS** |
| 14 | 3.24, edge | — |

Each release ships exactly one Ansible version, so the release *is* the version
selector. Ubuntu has no 14 at all — 26.10 still carries 13.1.0 — so Ubuntu's
DEVELOPMENT image needs pip regardless of which Ubuntu is chosen.

Rather than let the channel drag the OS along (which would put Alpine's two
images on different Alpine releases), the OS is pinned per variant: both Alpine
images on 3.23, both Ubuntu images on 26.04. STABLE comes from the package
manager; DEVELOPMENT always comes from pip. One OS per variant, one install
method per channel.

## Repository Layout

```
Containerfile.alpine-stable
Containerfile.alpine-development
Containerfile.ubuntu-stable
Containerfile.ubuntu-development
Makefile
.dockerignore
test/smoke.yml
README.md
```

Four explicit Containerfiles, no build args. Package-manager differences stay
visible in each file instead of hiding behind shell conditionals, at the cost of
some duplicated boilerplate that must be kept in sync.

## Containerfiles

### Common structure

Every file sets the same static OCI labels, `WORKDIR /apps`, and a `CMD` of the
OS's interactive shell. There is **no `ENTRYPOINT`** — the documented usage
passes the binary explicitly (`podman run ... ansible:alpine-stable ansible-playbook ...`),
so the image is a plain command host.

Static labels (in the Containerfiles):

```
org.opencontainers.image.title=ansible
org.opencontainers.image.description=<per variant>
org.opencontainers.image.licenses=GPL-3.0-only
org.opencontainers.image.source=https://github.com/pdutton/container-ansible
org.opencontainers.image.url=https://github.com/pdutton/container-ansible
org.opencontainers.image.vendor=pdutton
org.opencontainers.image.base.name=<base image>
```

`GPL-3.0-only` because `LICENSE` is the plain GPLv3 text with no "or later"
election.

Dynamic labels (`created`, `revision`, `version`) are supplied by the Makefile
via `podman build --label`, keeping the Containerfiles free of build args.

### STABLE variants

Alpine's `ansible` package depends only on `python3` and `ansible-core` — it
pulls **no SSH client** — so `openssh-client-default` is required, not optional.
`openssh-client` on Alpine is only a *provides* alias claimed by both
`openssh-client-default` and `openssh-client-krb5`, so the concrete name must be
used.

```dockerfile
RUN apk add --no-cache \
      ansible openssh-client-default sshpass \
      py3-jmespath py3-passlib py3-xmltodict py3-requests py3-argcomplete
```

Ubuntu uses `--no-install-recommends` plus an explicit list. Measured sizes:

| Build | Size |
|---|---|
| `ubuntu:26.04` base | 112 MB |
| with recommends | 715 MB |
| no recommends + explicit list | **664 MB** |
| no recommends, bare | 651 MB |

apt's recommends tree adds 31 packages mixing real functionality with ballast.
The explicit list keeps the functional ones and sheds ~51 MB of X11 (pulled in
only because `openssh-client` recommends `xauth` for X forwarding), Sphinx docs
JS, and Babel locale data. Dropping recommends entirely saves just 13 MB more
while breaking the `json_query` and `password_hash` filters, the `xml` module,
and all Windows/WinRM and Kerberos connectivity — a poor trade.

```dockerfile
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ansible openssh-client sshpass \
      python3-jmespath python3-passlib python3-xmltodict python3-selinux \
      python3-winrm python3-pyspnego python3-requests-ntlm \
      python3-kerberos python3-gssapi python3-requests python3-argcomplete \
 && rm -rf /var/lib/apt/lists/*
```

### DEVELOPMENT variants

Both bases mark system Python as PEP 668 externally-managed (Alpine 3.23 →
Python 3.12, Ubuntu 26.04 → Python 3.14), so pip cannot install into system
site-packages. A venv is used rather than `--break-system-packages`: it leaves
the distro Python untouched, which matters for the "use as a base image" case,
and the Ansible install cannot be clobbered by a later `apk`/`apt` operation.

```dockerfile
RUN <install python3, pip, venv support, ssh client> \
 && python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir "ansible>=14,<15"
ENV PATH="/opt/ansible/bin:$PATH"
```

**Known risk:** `pip install ansible` on musl may need `gcc`, `musl-dev`,
`python3-dev`, `libffi-dev` and `openssl-dev` if no `musllinux` wheel exists for
`cryptography`. If so, install them as an `apk --virtual` build group and delete
them within the same layer. To be resolved during implementation.

### Capability difference between the OSes

Alpine has no packages for `winrm`, `pyspnego`, `requests-ntlm`, `kerberos`,
`gssapi`, or `selinux`. Alpine images therefore do **not** support Windows/WinRM
or Kerberos targets. `jmespath`, `passlib`, `xmltodict`, `requests` and
`argcomplete` are available on both, so `json_query` and `password_hash` work
everywhere. This difference is documented in the README, not worked around.

## .dockerignore

Nothing is `COPY`d in Phase 1, so this exists purely to keep the build context
near-empty:

```
.git/
docs/
test/
Makefile
README.md
LICENSE
```

Podman also honors `.containerignore`; `.dockerignore` is used for portability
with Docker.

## Makefile

```make
IMAGE    ?= ansible
VARIANTS := alpine-stable alpine-development ubuntu-stable ubuntu-development
```

Targets: `build-<variant>`, `test-<variant>`, `build` and `test` (all four),
`clean`, and `help` as the default goal.

### Build

```
podman build -f Containerfile.$* -t $(IMAGE):$* \
  --label org.opencontainers.image.created=$(shell date -u +%Y-%m-%dT%H:%M:%SZ) \
  --label org.opencontainers.image.revision=$(shell git rev-parse HEAD) .
```

### Version tagging

`ansible-community --version` prints the *bundle* version (`Ansible community
version 13.1.0`) and ships with the `ansible` package on all four variants. It
is the portable source of truth across apk, apt, and pip. (`ansible --version`
reports the *core* version — 2.20.1 — which is a different number and not what
the tags use.)

After a successful build, the Makefile reads that version from the fresh image
and applies both `org.opencontainers.image.version` and a version tag in a
one-line `FROM`+`LABEL` pass. `alpine-stable` therefore yields both
`ansible:alpine-stable` and `ansible:alpine-13.0.0`. The version is read from
the image, never typed, so tags cannot drift from reality.

The extra pass costs one empty layer. The alternative — a hand-maintained
version per variant in the Makefile — was rejected as guaranteed to go stale.

## Testing

`test/smoke.yml` runs against localhost with `-c local`:

```
podman run --rm -v ./test:/apps:ro ansible:$* \
  ansible-playbook -i localhost, -c local smoke.yml -e expect_major=13
```

The Makefile passes `expect_major` per channel (13 for STABLE, 14 for
DEVELOPMENT). The playbook asserts:

1. The bundle major matches `expect_major` — the guard against a distro bump
   silently redefining a channel.
2. `json_query` works (proves jmespath is present).
3. `password_hash` works (proves passlib is present).
4. A `copy` + `file` task succeeds.
5. `ssh` is on `PATH`.

Each assertion covers a package that was deliberately installed, so a missing
dependency fails the test rather than surfacing later in a user's playbook.

## Error Handling

Make halts on any non-zero exit, so a broken build never reaches tagging and a
failed assert never yields a green `make test`. The version-tagging step fails
loudly if `ansible-community` is absent rather than falling back to an
unversioned tag.

## Out of Scope

Deferred to later phases: pushing to a registry, multi-arch (arm64) manifests,
CI, the `latest` tag, and Ansible majors other than the two current channels.
