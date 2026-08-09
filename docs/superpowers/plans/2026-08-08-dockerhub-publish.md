# Docker Hub Publish and CI Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the four Ansible image variants to `docker.io/pdutton/ansible` under a tag scheme whose dynamic tags always resolve to the newest relevant build, then drive that build-test-publish cycle from GitHub Actions.

**Architecture:** The Makefile owns the entire tag scheme. A single shell snippet, `TAG_SET_SH`, derives the full tag list for a variant from the bundle version detected inside the freshly built image; `tag-%` applies that list locally and `push-%` mirrors it to the registry. The GitHub Actions workflow is deliberately thin — a four-way matrix that runs `make test-<variant>` (build and smoke-test only) except when the ref is `master` and the event isn't a pull request, in which case it runs `make push-<variant>` instead (which builds, tests, and publishes in one invocation). **Amended during implementation:** publishing turned out to need restricting to `master`, not merely excluding pull requests — see Task 4.

**Tech Stack:** GNU Make, Podman 5.x, GitHub Actions, Docker Hub registry, Ansible (community bundle).

## Global Constraints

These apply to **every** task. Values are exact — do not substitute near-equivalents.

- Working directory is the worktree `/home/pdutton/projects/container-ansible/feature/dockerhub-publish`. Use `git -C <worktree>` for all git commands. **Never commit in `primary/`.**
- Docker Hub repository: `docker.io/pdutton/ansible`, public. Makefile variable `REGISTRY ?= docker.io/pdutton`.
- Local image name stays `ansible`; local tags stay `localhost/ansible:<tag>`. **Never create a registry-qualified local tag** — `podman push SOURCE DESTINATION` sends a localhost tag straight to the remote, and `make clean`'s localhost-anchored match depends on this.
- The four variant names, used verbatim as Containerfile suffixes, image tags, and Make target suffixes: `alpine-stable`, `alpine-development`, `ubuntu-stable`, `ubuntu-development`.
- `LATEST_VARIANT := ubuntu-stable`. `latest` is applied to that variant and no other.
- The bare-OS tag (`alpine`, `ubuntu`) is applied when and only when the channel is `stable`.
- The major tag comes from the **detected version**, never from the existing `major-stable` / `major-development` variables. Those two exist solely to feed the smoke test's `expect_major` assertion, and they must remain able to disagree with the tags — that disagreement is the alarm that a distro bump has redefined a channel.
- Version detection keeps the Phase 1 validation: a value not matching `[0-9]*.[0-9]*.[0-9]*` is a hard error with a message on stderr and a non-zero exit, never a silently-empty tag.
- Both phases build and publish `linux/amd64` only. No multi-arch, no manifest lists, no qemu.
- No cron / `schedule:` trigger in the workflow.
- Commit after every task.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Makefile` | The single place the tag scheme is defined, applied, and pushed | Modify |
| `.github/workflows/build.yml` | Run `make test-<variant>` except on a non-pull-request `master` ref, where `make push-<variant>` runs instead | Create |
| `README.md` | Document the published repo, the 15 tags, their mutability, and CI | Modify |
| `docs/superpowers/specs/2026-08-08-dockerhub-publish-design.md` | The approved design | Unchanged |

No Containerfile changes. No changes to `test/smoke.yml` — it already validates image contents, and the tag scheme is verified by asserting on tag existence and image identity rather than by a new test harness.

Task order is dependency order: local tags before pushing them, pushing before automating the push, and each phase's README changes folded into the task that makes them true.

---

### Task 1: Apply the full tag set locally

Rename `version-tag-%` to `tag-%` and grow it from producing two tags to producing the whole set. Nothing pushes yet — this task's deliverable is that a local `make build` leaves all 15 tags on the machine.

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `REGISTRY` (default `docker.io/pdutton`), `LATEST_VARIANT` (`ubuntu-stable`), and `TAG_SET_SH` — a recursively-expanded Make variable holding a single-line shell snippet that, given `$version` already set in the shell and `$*` set by the pattern rule, sets `$tags` to the space-separated tag list. Task 2's `push-%` expands the same variable.
- Produces: pattern target `tag-%`, replacing `version-tag-%`. `build-%` invokes it as `$(MAKE) --no-print-directory tag-$*`.

- [ ] **Step 1: Write the failing test**

This is the assertion that the full tag set exists. `podman image exists` exits non-zero when a tag is absent, so the loop is a real pass/fail check.

Save nothing — run it directly:

```bash
cd /home/pdutton/projects/container-ansible/feature/dockerhub-publish
for t in alpine-stable alpine-13 alpine-13.0.0 alpine; do
  podman image exists "ansible:$t" && echo "PRESENT $t" || { echo "MISSING  $t"; }
done
```

- [ ] **Step 2: Run it to verify it fails**

```bash
make build-alpine-stable
for t in alpine-stable alpine-13 alpine-13.0.0 alpine; do
  podman image exists "ansible:$t" && echo "PRESENT $t" || echo "MISSING  $t"
done
```

Expected: `alpine-stable` and `alpine-13.0.0` PRESENT (Phase 1 already made those), `alpine-13` and `alpine` MISSING.

If `alpine-13.0.0` is not the version reported, substitute whatever `podman run --rm ansible:alpine-stable ansible-community --version` prints and use that throughout this task.

- [ ] **Step 3: Add the new variables**

In `Makefile`, immediately after the `PODMAN ?= /usr/bin/podman` line, add:

```make
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
```

**Amended during implementation:** `LOCAL_IMAGE` was not part of the original
plan for this step; it was added once the podman short-name resolution risk on
the push source (Task 2) was identified, and applied everywhere a local image
is referenced, not just there. The code blocks below reflect the as-built
form.

- [ ] **Step 4: Add the tag-set snippet**

In `Makefile`, immediately after the `winrm-ubuntu := true` line, add:

```make
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
```

- [ ] **Step 5: Replace `version-tag-%` with `tag-%`**

Delete the entire existing `version-tag-%` target — its comment block and recipe — and put this in its place:

```make
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
```

(As-built; the original step used a bare `$(IMAGE)` throughout before `LOCAL_IMAGE` was introduced — see Step 3's note.)

The derived image is built once under the channel tag and then `podman tag`-ed to every other name, rather than passing a variable-length list of `-t` flags to the build. `$tags` contains `$*` itself; re-tagging an image to the name it already has is a no-op.

- [ ] **Step 6: Update the `build-%` call site**

In `Makefile`, in the `build-%` recipe, change the last line from:

```make
	@$(MAKE) --no-print-directory version-tag-$*
```

to:

```make
	@$(MAKE) --no-print-directory tag-$*
```

- [ ] **Step 7: Update the `clean` comment**

The comment above `clean` claims this repo applies two tags per variant. Replace the first sentence of that comment block. Change:

```make
# Removes the two tags this repo applies per variant (<os>-<channel> and
# <os>-<version>). It does NOT reclaim the orphaned <none> base layers each
```

to:

```make
# Removes every tag this repo applies -- three to five per variant:
# <os>-<channel>, <os>-<major>, <os>-<version>, plus <os> on the stable
# variants and `latest` on $(LATEST_VARIANT). Push never creates a
# registry-qualified local tag, so the localhost-anchored match below still
# covers the complete set. It does NOT reclaim the orphaned <none> base layers each
```

Leave the rest of that comment block and the `clean` recipe untouched — the existing `^(localhost/)?$(IMAGE):` match already covers the new tags.

- [ ] **Step 8: Run the test to verify it passes**

```bash
make clean
make build-alpine-stable
for t in alpine-stable alpine-13 alpine-13.0.0 alpine; do
  podman image exists "ansible:$t" && echo "PRESENT $t" || echo "MISSING  $t"
done
podman image exists ansible:latest && echo "WRONG: latest on alpine-stable" || echo "OK: no latest yet"
```

Expected: all four PRESENT, and `OK: no latest yet`.

- [ ] **Step 9: Verify the two conditional tags are actually conditional**

Both `<os>` and `latest` are applied only under a condition, so they must be tested against a variant that should *not* receive them. Start from a clean slate so an earlier build cannot supply the tag:

```bash
make clean
make build-alpine-development
podman image exists ansible:alpine  && echo "WRONG: bare-os tag on a development variant" || echo "OK: no bare alpine tag"
podman image exists ansible:latest  && echo "WRONG: latest on a non-LATEST_VARIANT"       || echo "OK: no latest tag"
for t in alpine-development alpine-14 alpine-14.2.0; do
  podman image exists "ansible:$t" && echo "PRESENT $t" || echo "MISSING  $t"
done
```

Expected: both `OK` lines, and all three tags PRESENT. Substitute the actual detected version for `14.2.0` if it differs.

Now build the variant that *should* get both:

```bash
make build-ubuntu-stable
for t in ubuntu-stable ubuntu-13 ubuntu-13.1.0 ubuntu latest; do
  podman image exists "ansible:$t" && echo "PRESENT $t" || echo "MISSING  $t"
done
for t in latest ubuntu ubuntu-13 ubuntu-stable; do
  printf '%-16s %s\n' "$t" "$(podman image inspect --format '{{.Id}}' ansible:$t)"
done
```

Expected: all five PRESENT, and four identical image IDs.

- [ ] **Step 10: Confirm nothing else broke**

`help` and `.PHONY` are Task 2's to change — `tag-%` is internal and is not listed. Confirm the rename left both targets working:

```bash
make help
make clean
podman images --format '{{.Repository}}:{{.Tag}}' | grep 'ansible:' || echo "all tags removed"
```

Expected: `help` prints the target list, and `clean` removes every tag including the new `ubuntu`, `ubuntu-13`, and `latest`.

- [ ] **Step 11: Commit**

```bash
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish add Makefile
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish commit -m "Apply the full tag set locally: os, major, version, and latest"
```

---

### Task 2: Push targets

Add `push-%` and `push`. This task publishes nothing — Docker Hub credentials arrive in Task 3. The deliverable is that the targets exist, sit correctly in the dependency graph, and fail loudly rather than quietly when they cannot push.

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Consumes: `REGISTRY`, `LATEST_VARIANT`, `TAG_SET_SH` from Task 1.
- Produces: pattern target `push-%` (depends on `test-%`) and aggregate target `push`. Task 4's workflow invokes `make push-<variant>`.

- [ ] **Step 1: Write the failing test**

```bash
cd /home/pdutton/projects/container-ansible/feature/dockerhub-publish
make push-alpine-stable
```

- [ ] **Step 2: Run it to verify it fails**

Expected: `make: *** No rule to make target 'push-alpine-stable'.  Stop.`

- [ ] **Step 3: Add the push targets**

In `Makefile`, immediately after the `test-%` target, add:

```make
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
```

(As-built, using `LOCAL_IMAGE` — see Task 1 Step 3's note. The push source in
particular is why `LOCAL_IMAGE` was introduced in the first place: this line
is the one that reaches an external registry if short-name resolution guesses
wrong.)

- [ ] **Step 4: Verify the label read works**

The inspect format above reads podman's top-level `Labels` map. Confirm it returns the version rather than `<no value>`:

```bash
make build-alpine-stable
podman image inspect --format '{{index .Labels "org.opencontainers.image.version"}}' ansible:alpine-stable
```

Expected: a bare version like `13.0.0`.

If it prints `<no value>` or an empty line, change `.Labels` to `.Config.Labels` in the `push-%` recipe and re-run this step. Do not proceed until it prints a version — an empty value here is exactly the failure the `case` guard is there to catch, and you want to know now rather than mid-push.

- [ ] **Step 5: Add `push` to `.PHONY` and `help`**

Change the `.PHONY` line from:

```make
.PHONY: help build test clean
```

to:

```make
.PHONY: help build test push clean
```

In the `help` recipe, add a `push` line after the `test` line and a `push-$(v)` entry to the `foreach`. The recipe becomes:

```make
help:
	@echo "Targets:"
	@echo "  build                 Build all four variants"
	@echo "  test                  Smoke-test all four variants"
	@echo "  push                  Push all four variants to $(REGISTRY)/$(IMAGE)"
	@echo "  clean                 Remove all tagged images built by this repo"
	@$(foreach v,$(VARIANTS),echo "  build-$(v)"; echo "  test-$(v)"; echo "  push-$(v)";)
	@echo
	@echo "Variants: $(VARIANTS)"
```

- [ ] **Step 6: Verify the target exists and is wired correctly**

```bash
make help
```

Expected: `push` and the four `push-<variant>` entries appear, and the `push` line names `docker.io/pdutton/ansible`.

```bash
podman logout docker.io || true
make push-alpine-stable
```

Expected: the build and smoke test run, then the first `Pushing docker.io/pdutton/ansible:...` line, then a failure from podman about authentication or a missing repository, and a non-zero exit from make. A silent success here would mean the push is not actually reaching the registry.

- [ ] **Step 7: Commit**

```bash
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish add Makefile
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish commit -m "Add push targets mirroring the tag set to the registry"
```

---

### Task 3: Seed publish and document it

Create the Docker Hub repository, publish all four variants by hand, verify every dynamic tag resolves to the right image, and update the README to describe what is now true. This task completes Phase 2.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `make push` from Task 2.
- Produces: a populated `docker.io/pdutton/ansible` repository and a Docker Hub Personal Access Token, which Task 4 stores as a repository secret.

- [ ] **Step 1: Create the Docker Hub repository and token**

Manual, in a browser at hub.docker.com:

1. Create repository `ansible` under the `pdutton` namespace, visibility **public**.
2. Under Account Settings → Personal access tokens, create a token with **Read & Write** scope. Copy it somewhere safe; Docker Hub shows it once. This is what Task 4 stores as `DOCKERHUB_TOKEN` — the account password must not be used.

- [ ] **Step 2: Log in**

```bash
podman login docker.io -u pdutton
```

Paste the token as the password. Expected: `Login Succeeded!`.

- [ ] **Step 3: Publish all four variants**

```bash
cd /home/pdutton/projects/container-ansible/feature/dockerhub-publish
make push
```

Expected: four builds, four smoke tests, and 15 `Pushing ...` lines in total. Exit status 0.

- [ ] **Step 4: Write the failing test — verify the tags from the registry**

Drop every local copy of the registry-qualified names first, so the pulls below genuinely resolve through Docker Hub:

```bash
podman images --format '{{.Repository}}:{{.Tag}}' \
  | grep '^docker.io/pdutton/ansible:' | xargs -r podman rmi -f
```

Then pull each tag back and print the image it resolved to:

```bash
REPO=docker.io/pdutton/ansible
for t in alpine alpine-stable alpine-13 alpine-13.0.0 \
         alpine-development alpine-14 alpine-14.2.0 \
         latest ubuntu ubuntu-stable ubuntu-13 ubuntu-13.1.0 \
         ubuntu-development ubuntu-14 ubuntu-14.2.0; do
  podman pull -q "$REPO:$t" >/dev/null
  printf '%-22s %s\n' "$t" "$(podman image inspect --format '{{.Id}}' "$REPO:$t")"
done
```

Substitute the actual detected versions for `13.0.0` / `13.1.0` / `14.2.0` if they differ.

Expected: every tag pulls, and the IDs fall into exactly four groups:

| Group | Tags |
|---|---|
| alpine stable | `alpine`, `alpine-stable`, `alpine-13`, `alpine-13.0.0` |
| alpine development | `alpine-development`, `alpine-14`, `alpine-14.2.0` |
| ubuntu stable | `latest`, `ubuntu`, `ubuntu-stable`, `ubuntu-13`, `ubuntu-13.1.0` |
| ubuntu development | `ubuntu-development`, `ubuntu-14`, `ubuntu-14.2.0` |

Any tag whose ID does not match its group is a defect in `TAG_SET_SH` — fix it before continuing.

- [ ] **Step 5: Smoke-test a published image**

Prove the published bytes work, not just the locally built ones:

```bash
podman run --rm -v ./test:/apps:ro,z docker.io/pdutton/ansible:latest \
  ansible-playbook -i localhost, -c local smoke.yml \
  -e expect_major=13 -e expect_winrm=true
```

Expected: the playbook completes with `failed=0`.

- [ ] **Step 6: Update the README usage examples**

In `README.md`, in the "Usage Examples" section, change both alias bodies from `localhost/ansible:alpine-stable` to `docker.io/pdutton/ansible:alpine-stable`. The two lines become:

```
alias ansible='podman run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps docker.io/pdutton/ansible:alpine-stable ansible'
```

```
alias ansible-playbook='podman run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps docker.io/pdutton/ansible:alpine-stable ansible-playbook'
```

- [ ] **Step 7: Replace the Tags section**

In `README.md`, replace the whole `### Tags` subsection — from the `### Tags` heading through the paragraph beginning "The eight tags that exist after a full build" — with:

````markdown
### Published Images

Images are published to [`pdutton/ansible`](https://hub.docker.com/r/pdutton/ansible) on Docker Hub:

```bash
podman pull docker.io/pdutton/ansible:alpine-stable
docker pull pdutton/ansible:latest
```

A local build carries the identical tag set.

### Tags

| Tag | Resolves to |
|---|---|
| `latest` | `ubuntu-stable` — the variant with no capability gaps, on the conservative channel |
| `ubuntu`, `alpine` | that OS's `stable` variant |
| `<os>-stable`, `<os>-development` | newest build of that channel on that OS |
| `<os>-<major>` — `alpine-13`, `ubuntu-14` | newest build of that Ansible major on that OS |
| `<os>-<version>` — `alpine-13.0.0` | newest build of that exact bundle version |

The major tag follows the *version*, not the channel. When stable eventually moves to Ansible 14, `ubuntu-14`
starts being produced by `ubuntu-stable` rather than `ubuntu-development` — which is what "the newest 14 on
Ubuntu" ought to mean.

Version and major tags are derived at build time by reading `ansible-community --version` out of the freshly
built image, so they always reflect what is actually installed. You can read the same value yourself:

```bash
podman run --rm docker.io/pdutton/ansible:alpine-stable ansible-community --version
```

The 15 tags that exist after a full build:

```
alpine-stable        alpine-13   alpine-13.0.0    alpine
alpine-development   alpine-14   alpine-14.2.0
ubuntu-stable        ubuntu-13   ubuntu-13.1.0    ubuntu    latest
ubuntu-development   ubuntu-14   ubuntu-14.2.0
```

#### Every tag here is mutable, including the version tags

`alpine-13.0.0` looks like a pin. It is not. A rebuild that again resolves to 13.0.0 re-pushes that tag at a
*new* image carrying fresher base-OS packages.

This is deliberate — it is how a base-image CVE fix reaches someone who pinned a version — but it means this
repo publishes no content-immutable tag at all. **If you need reproducibility, pin by digest**, which you can
capture with:

```bash
podman image inspect --format '{{index .RepoDigests 0}}' docker.io/pdutton/ansible:alpine-stable
```

For the `stable` variants the version tag only moves when the distro's packaged Ansible does. For the
`development` variants it moves on every build that picks up a newer 14.x from pip, since pip resolves whatever
the latest 14.x is at build time.
````

- [ ] **Step 8: Update the Building Locally section**

In `README.md`, in the "Building Locally" section, add `make push` to the command block. The block becomes:

```bash
make build                 # build all four variants
make test                  # smoke-test all four variants
make push                  # build, test, and publish all four to Docker Hub
make build-alpine-stable   # build just one variant
make clean                 # remove all tagged images this repo builds
```

Then, immediately after that block, add:

```markdown
`make build` applies the complete tag set locally, so a local build and a published one leave identical tag
state — which is what makes a CI publish reproducible on your own machine. `push-<variant>` depends on
`test-<variant>`, so a failing smoke test blocks the publish. Publishing requires `podman login docker.io`
first; override the destination with `make push REGISTRY=ghcr.io/pdutton`.
```

Also update the `make clean` paragraph below it: change "only removes the tags this repo applies (`<os>-<channel>` and `<os>-<version>` for each variant)" to "only removes the tags this repo applies (three to five per variant, listed above)".

- [ ] **Step 9: Trim the Planned section**

In `README.md`, in the "Planned" section, delete the first bullet (the tag-scheme one, beginning "A more familiar tag scheme"). Leave the multi-arch bullet. The section becomes:

```markdown
## Planned

The following are not implemented yet and should not be treated as available today:

- Multi-arch builds for both `amd64` and `arm64`.
```

- [ ] **Step 10: Verify the README claims are true**

Re-read the edited sections and check each concrete claim against the repository:

- Every tag named in the 15-tag block appeared in Step 4's output.
- The `RepoDigests` command prints a digest:
  ```bash
  podman image inspect --format '{{index .RepoDigests 0}}' docker.io/pdutton/ansible:alpine-stable
  ```
- `make push REGISTRY=...` is a real override — confirm `REGISTRY` uses `?=` in the Makefile.
- No `localhost/ansible` reference remains in the usage examples. The README already carries one deliberate
  mention — "Locally built images are referenced as `localhost/ansible:<tag>`, e.g. `localhost/ansible:ubuntu-stable`"
  at the end of the Image Variants section — which is why Step 7's replacement text does not repeat it.
  ```bash
  grep -n 'localhost/ansible' README.md
  ```
  Expected: exactly one matching line, that one. Any match on an `alias` line means Step 6 was not applied.

- [ ] **Step 11: Commit**

```bash
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish add README.md
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish commit -m "Document the published Docker Hub images and the 15-tag scheme"
```

---

### Task 4: GitHub Actions workflow

Add the workflow and its secrets. On a pull request it builds and smoke-tests all four variants and pushes nothing; on a master push or manual dispatch it also publishes.

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `make test-<variant>` and `make push-<variant>` from Tasks 1–2; the Docker Hub PAT from Task 3.
- Produces: a workflow named `build`, referenced by the README badge in Task 5.

- [ ] **Step 1: Store the secrets**

```bash
gh secret set DOCKERHUB_USERNAME --repo pdutton/container-ansible --body pdutton
gh secret set DOCKERHUB_TOKEN --repo pdutton/container-ansible
```

The second command prompts for the value — paste the Read & Write PAT from Task 3, not the account password.

Verify:

```bash
gh secret list --repo pdutton/container-ansible
```

Expected: both names listed.

- [ ] **Step 2: Write the failing test**

The test is the workflow run itself. Confirm there is nothing to run yet:

```bash
gh workflow list --repo pdutton/container-ansible
```

Expected: no `build` workflow.

- [ ] **Step 3: Create the workflow**

Create `.github/workflows/build.yml`:

```yaml
name: build

on:
  pull_request:
  push:
    branches: [master]
  workflow_dispatch:

# Nothing here writes to the repository.
permissions:
  contents: read

# Cancel superseded pull-request runs, but let a master push finish -- a
# cancellation mid-push would leave a variant's tag set half-updated in the
# registry.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  build:
    name: ${{ matrix.variant }}
    runs-on: ubuntu-latest
    strategy:
      # One variant's failure must not stop the other three from publishing.
      # alpine-development resolves whatever 14.x pip serves that day and is
      # the most exposed to upstream change.
      fail-fast: false
      matrix:
        variant:
          - alpine-stable
          - alpine-development
          - ubuntu-stable
          - ubuntu-development

    steps:
      - uses: actions/checkout@v4

      # Default checkout depth is fine: the Makefile's `git rev-parse HEAD`
      # works at depth 1.

      - name: Ensure podman
        run: |
          if ! command -v podman >/dev/null; then
            sudo apt-get update
            sudo apt-get install -y podman
          fi
          # The Makefile defaults to absolute tool paths; fail loudly here
          # rather than with a confusing "no such file" mid-build.
          test -x /usr/bin/podman
          test -x /usr/bin/awk
          podman --version

      # Publishing happens only from master. A dispatch against another branch
      # still builds and smoke-tests, so a branch can be put through CI, but it
      # must never overwrite the shared mutable tags (latest, alpine, ubuntu,
      # <os>-<major>) with unreviewed code. This condition is the exact negation
      # of the publish condition below -- if it were merely the pull_request
      # check, a dispatch from a feature branch would match no step at all and
      # the job would silently do nothing.
      - name: Build and smoke-test
        if: github.event_name == 'pull_request' || github.ref != 'refs/heads/master'
        run: make test-${{ matrix.variant }}

      - name: Log in to Docker Hub
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        env:
          DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
        run: printf '%s' "$DOCKERHUB_TOKEN" | podman login docker.io -u "$DOCKERHUB_USERNAME" --password-stdin

      # One invocation, not two: push-<variant> depends on test-<variant> which
      # depends on build-<variant>, so this builds, smoke-tests, and publishes.
      # Running `make test-` in a separate step first would repeat the whole
      # chain -- these pattern targets match no real file, so Make re-runs them
      # on every invocation.
      - name: Build, smoke-test, and push
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        run: make push-${{ matrix.variant }}
```

**Amended during implementation:** the shape above is not what this step
originally specified. Two problems surfaced while implementing it:

1. Excluding only pull requests would have let `workflow_dispatch` against a
   non-master branch publish, and it would let *every* push branch publish if
   this workflow ever gained a `push:` trigger beyond `master` — publishing
   needed to be restricted to `master` specifically, not merely "not a pull
   request".
2. The original two-step split — an unconditional `make test-<variant>` step,
   then a separately-guarded `make push-<variant>` step — would have rebuilt
   the whole chain twice on the publishing path: `build-%`/`test-%`/`push-%`
   match no real files, so a second, separate `make` invocation re-runs them
   rather than seeing the first invocation's work as already done. The
   as-built workflow instead has exactly one `make` step per branch, gated by
   conditions that are exact complements of each other, so every run does
   precisely one of "test" or "build+test+push".

Two further details that are load-bearing:

- The `Ensure podman` step uses `if ... fi`, not `command -v podman || sudo apt-get update && sudo apt-get install -y podman`. Shell parses `a || b && c` as `(a || b) && c`, so the one-liner form installs podman *even when it is already present* — a quiet minute wasted on every run.
- The secrets reach the login step through `env:` rather than being interpolated directly into the `run:` script. A secret containing shell metacharacters cannot then alter the command.

- [ ] **Step 4: Commit and push the branch**

```bash
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish add .github/workflows/build.yml
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish commit -m "Add GitHub Actions workflow building, testing, and publishing the four variants"
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish push -u origin feature/dockerhub-publish
```

- [ ] **Step 5: Open a pull request and run the test**

```bash
gh pr create --repo pdutton/container-ansible --base master --head feature/dockerhub-publish \
  --title "Publish images to Docker Hub and build them in CI" \
  --body "Implements docs/superpowers/specs/2026-08-08-dockerhub-publish-design.md"
```

**Check `mergeable_state` before polling for a run.** `pull_request` workflows
run against GitHub's synthetic merge commit at `refs/pull/N/merge`, which
GitHub computes lazily and only when the PR is actually mergeable. If there is
a merge conflict, that ref never materializes and no run is ever scheduled —
`gh pr checks --watch` then just polls forever with nothing to show, which is
exactly what happened once during this implementation (a ~6 minute stall
before the cause was found). Confirm before waiting:

```bash
gh pr view --repo pdutton/container-ansible --json mergeable,mergeStateStatus
```

Expected: `"mergeable": "MERGEABLE"`. If it instead reports `CONFLICTING`,
resolve the conflict and push before proceeding — a run will not appear no
matter how long you wait. Only once this is confirmed:

```bash
gh pr checks --repo pdutton/container-ansible --watch
```

Expected: four jobs named `alpine-stable`, `alpine-development`, `ubuntu-stable`, `ubuntu-development`, all passing.

- [ ] **Step 6: Verify the pull request published nothing**

Confirm the `Log in to Docker Hub` and `Push` steps were skipped:

```bash
gh run view --repo pdutton/container-ansible --log-failed || true
gh run list --repo pdutton/container-ansible --workflow build --limit 1
```

Open the run in the browser (`gh run view --web`) and confirm both credentialed steps show as skipped on all four jobs.

Then confirm the registry is untouched — record the digest of `latest` before and after:

```bash
podman pull -q docker.io/pdutton/ansible:latest >/dev/null
podman image inspect --format '{{index .RepoDigests 0}}' docker.io/pdutton/ansible:latest
```

Expected: the same digest Task 3 published. A changed digest means the pull-request guard is not working.

---

### Task 5: Document CI and verify the publish path

Add the badge and the CI section, then verify the publishing path end to end after the merge.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the `build` workflow from Task 4.

- [ ] **Step 1: Add the badge**

In `README.md`, directly under the `# container-ansible` heading and above the `Container Image with Ansible` line, add:

```markdown
[![build](https://github.com/pdutton/container-ansible/actions/workflows/build.yml/badge.svg)](https://github.com/pdutton/container-ansible/actions/workflows/build.yml)
```

- [ ] **Step 2: Add the CI section**

In `README.md`, insert a new section immediately before `## License`:

```markdown
## Continuous Integration

`.github/workflows/build.yml` builds and smoke-tests all four variants in parallel on every pull request, and
additionally publishes them on a push to `master` or a `workflow_dispatch` run against `master`. Pull requests
never receive registry credentials and never push.

There is no scheduled rebuild. The `development` variants resolve whatever 14.x pip serves at build time, and a
base-image security fix only reaches the published images when a build is triggered — so refreshing them is a
deliberate act: merge to `master`, or run the workflow from the Actions tab.
```

**Amended during implementation:** the original text here said "on a push to
`master` or a manual `workflow_dispatch`", unqualified — false, and
contradicted by the very next paragraph's master-only restriction (added to
the shipped README but not back-ported to this plan text until now). A
`workflow_dispatch` run against a non-master branch builds and smoke-tests but
publishes nothing.

- [ ] **Step 3: Commit and push**

```bash
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish add README.md
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish commit -m "Document CI and the absence of a scheduled rebuild"
git -C /home/pdutton/projects/container-ansible/feature/dockerhub-publish push
```

- [ ] **Step 4: Verify CI is still green, then merge**

```bash
gh pr checks --repo pdutton/container-ansible --watch
gh pr merge --repo pdutton/container-ansible --merge
```

- [ ] **Step 5: Run the test — verify the publish path**

Watch the master run:

```bash
gh run list --repo pdutton/container-ansible --workflow build --limit 1
gh run watch --repo pdutton/container-ansible
```

Expected: four jobs pass, and on each the `Log in to Docker Hub` and `Push` steps **ran** rather than being skipped.

Then re-run Task 3 Step 4's tag verification against the CI-published images:

```bash
podman images --format '{{.Repository}}:{{.Tag}}' \
  | grep '^docker.io/pdutton/ansible:' | xargs -r podman rmi -f

REPO=docker.io/pdutton/ansible
for t in alpine alpine-stable alpine-13 alpine-13.0.0 \
         alpine-development alpine-14 alpine-14.2.0 \
         latest ubuntu ubuntu-stable ubuntu-13 ubuntu-13.1.0 \
         ubuntu-development ubuntu-14 ubuntu-14.2.0; do
  podman pull -q "$REPO:$t" >/dev/null
  printf '%-22s %s\n' "$t" "$(podman image inspect --format '{{.Id}}' "$REPO:$t")"
done
```

Expected: the same four ID groups as Task 3, with IDs differing from the seed push (CI built fresh images).

- [ ] **Step 6: Verify `workflow_dispatch`**

```bash
gh workflow run build --repo pdutton/container-ansible
gh run watch --repo pdutton/container-ansible
```

Expected: four jobs pass with the login and push steps running.

- [ ] **Step 7: Clean up the worktree**

**Run the whole-branch review before this step, not after.** Removing the
worktree deletes the working tree a reviewer would diff against; a
final-review pass over the complete branch needs the worktree to still exist.

```bash
git -C /home/pdutton/projects/container-ansible/primary pull
git -C /home/pdutton/projects/container-ansible/primary worktree remove ../feature/dockerhub-publish
git -C /home/pdutton/projects/container-ansible/primary branch -d feature/dockerhub-publish
```

---

## Known Failure Modes

Recorded so an implementer recognises them rather than debugging from scratch:

| Symptom | Cause |
|---|---|
| `tag-%` aborts after the version check with no error message | `[ ... ] && ...` used instead of `if ... fi` in `TAG_SET_SH`; under `set -e` the false test kills the recipe |
| Tags come out as `alpine--13` or `-13.0.0` | `$$` escaping wrong in `TAG_SET_SH`, leaving a shell variable empty |
| `push-%` errors that the version label is unusable | `.Labels` is the wrong path for this podman version — use `.Config.Labels` (Task 2 Step 4) |
| CI installs podman on every run despite it being preinstalled | The `a \|\| b && c` precedence trap in the `Ensure podman` step |
| `make clean` leaves `latest` or `alpine` behind | A registry-qualified tag was created locally, escaping the `^(localhost/)?$(IMAGE):` match |
| A pull-request run pushes to Docker Hub, or a `workflow_dispatch` against a non-master branch pushes | Missing, misspelled, or non-complementary publish guard — as-built, publishing requires both `github.event_name != 'pull_request'` **and** `github.ref == 'refs/heads/master'` |
