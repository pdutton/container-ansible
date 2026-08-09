# Phases 2 & 3: Publish to Docker Hub, and Build It in CI

**Date:** 2026-08-08
**Status:** Approved

## Goal

Publish the four image variants to Docker Hub under a tag scheme whose dynamic
tags always resolve to the newest relevant build, and then have GitHub Actions
perform that build-test-publish cycle.

The two phases are specified together because Phase 3 adds no publishing logic
of its own. Phase 2 defines the tag scheme and the push mechanism in the
Makefile; Phase 3 is a thin workflow that calls it. Splitting them across two
specs would put the workflow's contract in a different document from the thing
it contracts with.

- **Phase 2** — Makefile gains the full tag set and `push` targets. Publishing
  is driven from a developer's machine.
- **Phase 3** — a GitHub Actions workflow runs the same targets on PRs (build
  and test only) and on master pushes and manual dispatch (build, test, push).

### Non-goals

Deliberately excluded, and to stay excluded until a later phase:

- **Multi-arch.** Both phases build and publish `linux/amd64` only. Multi-arch
  changes the shape of a push — you publish a manifest list rather than an
  image — and reading the bundle version back out of an `arm64` image requires
  qemu emulation. It earns its own phase. The README's "Planned" section keeps
  this bullet.
- **Scheduled rebuilds.** No cron trigger. See "Accepted risks".
- **Release-tag triggers**, Docker Hub description sync, and signing
  (cosign/sigstore).

## Registry Coordinates

| | |
|---|---|
| Repository | `docker.io/pdutton/ansible`, public |
| Local image name | `ansible` (unchanged) |
| Makefile override | `REGISTRY ?= docker.io/pdutton` |

The local image name stays `ansible`, so a local build remains
`localhost/ansible:<tag>` and `REGISTRY` alone retargets a push — `make push
REGISTRY=ghcr.io/pdutton` works without touching anything else.

## Tag Scheme

Every tag derives from one build of one variant. Given variant `<os>-<channel>`
whose bundle version, read out of the freshly built image, is `X.Y.Z`:

| Tag | Applied when | Meaning |
|---|---|---|
| `<os>-<channel>` | always | newest build of that channel |
| `<os>-<major>` | always | newest build of that Ansible major on that OS |
| `<os>-<X.Y.Z>` | always | newest build of that exact bundle version |
| `<os>` | `channel == stable` | that OS's stable image |
| `latest` | `variant == ubuntu-stable` | the default image |

`<major>` is the leading component of the detected version, not a constant tied
to the channel. The distinction matters on a future channel shift: when stable
moves to Ansible 14, `ubuntu-14` begins to be produced by `ubuntu-stable`
instead of `ubuntu-development`, which is the correct reading of "the newest 14
on Ubuntu" and requires no code change.

The Makefile's existing `major-stable := 13` / `major-development := 14`
variables must **not** be reused for tag math. They exist to feed the smoke
test's `expect_major` assertion — their purpose is to fail loudly when a distro
bump silently redefines a channel — and driving tags from them would require a
hand edit at exactly the moment it is easiest to forget. Tags come from the
detected version; the assertion stays hard-coded. They are meant to disagree.

`latest` points at `ubuntu-stable`. Ubuntu is the variant with no capability
gaps — WinRM, Kerberos, and SELinux support exist only there — and `stable` is
the conservative channel, so someone who runs `docker run pdutton/ansible`
without reading the tag table gets the image least likely to fail in a way they
can't diagnose. Choosing `alpine-stable` for its smaller size would make
`latest` silently unable to reach Windows hosts.

### The 15 tags after a full build

```
alpine-stable        alpine-13   alpine-13.0.0    alpine
alpine-development   alpine-14   alpine-14.2.0
ubuntu-stable        ubuntu-13   ubuntu-13.1.0    ubuntu    latest
ubuntu-development   ubuntu-14   ubuntu-14.2.0
```

Version numbers above are the values current on 2026-08-08 and will drift.

### Every tag is mutable, including the version tags

`<os>-<X.Y.Z>` is a moving pointer, not a content pin. A rebuild that again
resolves to 13.0.0 re-pushes `alpine-13.0.0` at a *new* image carrying fresher
base-OS packages.

This is intended: it is the mechanism by which a base-image CVE fix reaches
someone who pinned a version. But it means this repo publishes no
content-immutable tag at all, and `alpine-13.0.0` looks like an immutable pin to
anyone who hasn't been told otherwise. **The README must state this explicitly**
rather than let the tag's shape imply a guarantee it does not make. A consumer
who needs true immutability must pin by digest.

## Phase 2: Makefile

### Structural change

The existing `version-tag-%` target is renamed `tag-%` and computes the *whole*
tag set rather than only the version tag, applying all of it locally. The rename
is part of the change, not optional: `version-tag-%` would be a misleading name
for a target that now also produces `latest`. `build-%` continues to invoke it
under the new name, so a
plain `make build` now produces `alpine`, `alpine-13`, `latest`, and the rest
alongside the two tags it produced before. Local and published tag state are
therefore identical, which is what makes a CI publish reproducible on a
developer's machine.

Applying the tags happens in two steps rather than one multi-`-t` build: build
the derived version-labelled image once under `$(IMAGE):$*`, then `podman tag`
it to each remaining name. This keeps the `printf | podman build -f -` pipeline
unchanged from Phase 1 and avoids constructing a variable-length `-t` argument
list inside the build command.

### New targets

```make
REGISTRY       ?= docker.io/pdutton
LATEST_VARIANT := ubuntu-stable

push-%: test-%
	# push each tag in the computed set from localhost/$(IMAGE):<tag>
	# to $(REGISTRY)/$(IMAGE):<tag>

push: $(addprefix push-,$(VARIANTS))
```

`.PHONY` and `help` must both be updated to cover the new targets.

Three properties this shape guarantees:

- **`push-%` depends on `test-%`.** A smoke-test failure blocks the publish; a
  broken image cannot reach the registry through this path. `test-%` already
  depends on `build-%`, so a single `make push-alpine-stable` builds, tests, and
  publishes in dependency order, and repeated invocations within one job do not
  rebuild.
- **No registry-qualified local tags.** `podman push SOURCE DESTINATION` sends
  `localhost/ansible:alpine-13` to `docker.io/pdutton/ansible:alpine-13` without
  ever creating a local tag under the registry name. `make clean`'s existing
  `^(localhost/)?$(IMAGE):` regex therefore continues to match every tag this
  repo creates, including the new ones, and needs no change.
- **Pushing one image under five tags is cheap.** The layers upload once; each
  subsequent tag push transfers only a manifest.

### Tag math is defined once

Both the tagging target and the push target need the same list. That list must
be derived in exactly one place — a `define`d shell snippet invoked with
`$(call ...)`, or an equivalent single definition — not copied into two
recipes.

Two known traps, recorded here because both fail quietly:

- **`set -e` and `[ ... ] && ...`.** Under `set -eu`, a line like
  `[ "$channel" = stable ] && tags="$tags $os"` aborts the whole recipe when the
  test is false, because the compound command's exit status is non-zero. Use
  `if ... then ... fi`.
- **`$` escaping inside `define`.** A shell `$` needs `$$` in an ordinary
  recipe and `$$$$` inside a `define` expanded through `$(call ...)`. Getting
  this wrong yields an empty variable rather than an error.

The push target obtains the version without re-running a container by reading
the `org.opencontainers.image.version` label that the tagging step applied:
`podman image inspect --format '{{index .Labels "org.opencontainers.image.version"}}'`.

Version detection keeps the Phase 1 validation — a value not matching
`[0-9]*.[0-9]*.[0-9]*` is a hard error, never a silently-empty tag.

### Prerequisites

Manual, performed once, outside the code:

1. Create the public `pdutton/ansible` repository on Docker Hub.
2. Create a Docker Hub Personal Access Token with Read/Write scope. The token,
   not the account password, is what Phase 3 stores as a secret.
3. `podman login docker.io` on the machine performing the Phase 2 push.

### Verification

After the first `make push`, pull the published tags back from the registry —
not from local cache — and confirm each dynamic tag resolves to the image it
should:

- `alpine`, `alpine-13`, `alpine-13.0.0`, and `alpine-stable` all resolve to one
  image ID.
- `latest`, `ubuntu`, `ubuntu-13`, `ubuntu-13.1.0`, and `ubuntu-stable` all
  resolve to one image ID.
- `alpine-development`, `alpine-14`, `alpine-14.2.0` agree; likewise the Ubuntu
  development trio.
- A smoke test passes against an image pulled from Docker Hub, not the locally
  built one.

This is a documented manual procedure in the implementation plan, not a
permanent Makefile target. It is only meaningful against a clean pull, which a
convenient `make verify` would tend to skip.

## Phase 3: GitHub Actions

### Workflow

Single file, `.github/workflows/build.yml`.

```yaml
on:
  pull_request:
  push:
    branches: [master]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

`permissions: contents: read` — nothing in this workflow writes to the repo.

Concurrency cancels superseded PR runs but lets a master push finish, so a
cancellation cannot leave a variant's tag set half-updated in the registry.

### Matrix

One job per variant, over the four variant names, with `fail-fast: false`.

Rationale: the four builds run in parallel rather than serially; a failure
identifies the variant in the job list without reading logs; and `fail-fast:
false` means a broken `alpine-development` — the pip-resolved variant, the one
most exposed to upstream change — does not prevent the other three from
publishing.

Each job runs on `ubuntu-latest`:

1. `actions/checkout` at default depth. The Makefile's `git rev-parse HEAD`
   works at depth 1; no `fetch-depth: 0` is needed.
2. Ensure podman: `command -v podman || sudo apt-get install -y podman`.
   GitHub-hosted Ubuntu runners ship podman, but the guard costs nothing and
   survives a runner-image change — and it is a check, not an unconditional
   install, so it does not spend a minute on every run.
3. `make test-${{ matrix.variant }}` — builds, then smoke-tests.
4. Publish, guarded by `if: github.event_name != 'pull_request'`:
   `podman login docker.io` with the secrets, then
   `make push-${{ matrix.variant }}`.

Step 4 re-uses the images from step 3; Make's dependency graph prevents a
rebuild within the job.

### Secrets

`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` as repository secrets, the latter
being the PAT from Phase 2's prerequisites.

Pull requests from forks never receive secrets, and they never reach step 4, so
there is no path on which a fork PR fails for want of a credential.

### CI verification

1. A pull request builds and tests all four variants and pushes nothing —
   confirm the registry is untouched.
2. A merge to master publishes; re-run the Phase 2 tag verification against the
   CI-published images.
3. A `workflow_dispatch` run publishes.

## README Changes

Spanning both phases:

- Usage examples move from `localhost/ansible:alpine-stable` to
  `pdutton/ansible:alpine-stable`.
- The "Tags" section is rewritten around the 15-tag scheme, including the
  mutability caveat and the pin-by-digest note.
- A "Published images" section replaces the "Planned" tag-scheme bullet; the
  multi-arch bullet stays.
- A CI badge for the workflow.
- The "Building Locally" section gains `make push` and notes that a local build
  now applies the full tag set.

## Accepted Risks

**No scheduled rebuild.** Without a cron trigger, images are rebuilt only on a
master push or a manual dispatch. Two consequences, accepted deliberately:

- The `development` variants resolve whatever 14.x pip serves at build time, so
  a published `alpine-development` can sit at a stale 14.x indefinitely.
- A base-image security fix reaches the published images only when someone
  triggers a build.

`workflow_dispatch` makes refreshing the images a one-click deliberate act. Add
a cron trigger later if the manual step proves easy to forget.

**No immutable tags.** Covered above under the tag scheme. Consumers needing
reproducibility must pin by digest, and the README must say so.

## Rejected Alternatives

**Tag logic in the workflow via `docker/metadata-action` + `buildx`.** More
idiomatic GitHub Actions, but it would put the tag scheme somewhere that cannot
be run or debugged locally, and would split image-building between `buildx` in
CI and `podman` on a developer's machine. The Makefile-owns-it choice keeps one
implementation and one runtime.

**A `scripts/push.sh` called by both the Makefile and the workflow.** Same
single-source-of-truth benefit, but it introduces a third artifact where the
Makefile already has the variant matrix and the version-detection logic.

**A single CI job building all four variants.** Simpler workflow file, but
serial, and a single failure obscures which variant broke and blocks the other
three from publishing.
