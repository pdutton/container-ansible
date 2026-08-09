# container-ansible

[![build](https://github.com/pdutton/container-ansible/actions/workflows/build.yml/badge.svg)](https://github.com/pdutton/container-ansible/actions/workflows/build.yml)

Container Image with Ansible

## Ansible Without Installing
This repo provides a container image that allows updated versions of ansible to be run on various os versions and
variants without requiring complex installs.

### Usage Examples:
```
alias ansible='podman run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps docker.io/pdutton/ansible:alpine-stable ansible'
ansible <follow command>
```

```
alias ansible-playbook='podman run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps docker.io/pdutton/ansible:alpine-stable ansible-playbook'
ansible-playbook -i inventory <follow command>
```

The alias body is single-quoted and uses `"$PWD"` rather than `$(pwd)` so the mount is resolved fresh on every
invocation. A double-quoted alias body substitutes `$(pwd)` once, at the moment the alias is *defined* — it then
permanently mounts that one directory no matter where you later `cd`, with no error to warn you.

On an SELinux-enforcing host (e.g. Fedora/RHEL), mounting your real `~/.ssh` needs
`--security-opt label=disable` added to the alias rather than a `:z`/`:Z` suffix on the mount — relabeling
`~/.ssh` with `:z` would alter the SELinux context of your actual SSH keys on the host, which is actively
harmful.

Swap `alpine-stable` for any of the other three tags below if you need a different base OS or Ansible channel.

## Ansible Base Image
The container image provided by this repo can also be used as a base image for downstream images.

On the `development` variants (`alpine-development`, `ubuntu-development`), Ansible runs from a venv at
`/opt/ansible`, not from the system Python. Install downstream Python dependencies you want Ansible modules to see
with `/opt/ansible/bin/pip`, not the system package manager.

- On `ubuntu-development` the venv is created with `--system-site-packages`, so it *also* sees anything installed
  via `apt` into the system Python — a downstream `apt-get install python3-something` is importable from Ansible
  there. `/opt/ansible/bin/pip` remains the more direct route and is guaranteed to take effect.
- On `alpine-development` the venv has no such visibility into `apk`-installed Python packages; only
  `/opt/ansible/bin/pip` reaches the interpreter Ansible uses.

The `stable` variants (`alpine-stable`, `ubuntu-stable`) run Ansible from the system Python directly, so the
system package manager (`apk`/`apt`) is the correct way to add downstream Python dependencies there.

## Image Variants

Four variants are built from this repo, each on its own Containerfile:

| Tag              | Base image     | Ansible channel | Bundle version | Install method    |
|------------------|-----------------|------------------|-----------------|--------------------|
| `alpine-stable`      | `alpine:3.23`  | stable (13.x)    | 13.0.0          | `apk`              |
| `alpine-development` | `alpine:3.23`  | development (14.x) | 14.2.0       | pip, venv at `/opt/ansible` |
| `ubuntu-stable`      | `ubuntu:26.04` | stable (13.x)    | 13.1.0          | `apt`              |
| `ubuntu-development` | `ubuntu:26.04` | development (14.x) | 14.2.0       | pip, venv at `/opt/ansible` |

Neither distro ships Ansible 14 in any suite as of this writing — even Ubuntu 26.10 carries 13.1.0, and Alpine 3.23
only carries 13 — so both `development` variants install via pip into a venv instead of the distro package manager.

Locally built images are referenced as `localhost/ansible:<tag>`, e.g. `localhost/ansible:ubuntu-stable`.

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

## Capability Differences

Alpine and Ubuntu are not equivalent targets. Alpine has no packages for `winrm`, `pyspnego`, `requests-ntlm`,
`kerberos`, `gssapi`, or `selinux`, so **the `alpine-stable` and `alpine-development` images do not support
Windows/WinRM or Kerberos-authenticated targets.** The `ubuntu-stable` and `ubuntu-development` images do support
both.

`json_query` (jmespath) and `password_hash` (passlib) work the same on all four variants.

If your playbooks target Windows hosts or rely on Kerberos, use one of the Ubuntu variants.

## Building Locally

Requires [Podman](https://podman.io/) and GNU Make.

```bash
make build                 # build all four variants
make test                  # smoke-test all four variants
make push                  # build, test, and publish all four to Docker Hub
make build-alpine-stable   # build just one variant
make clean                 # remove all tagged images this repo builds
```

`make build` applies the complete tag set locally, so a local build and a published one leave identical tag
state — which is what makes a CI publish reproducible on your own machine. `push-<variant>` depends on
`test-<variant>`, so a failing smoke test blocks the publish. Publishing requires `podman login docker.io`
first; override the destination with `make push REGISTRY=ghcr.io/pdutton`.

Run `make help` (or just `make`) to list every target, including the per-variant `build-<variant>` and
`test-<variant>` names (`test-<variant>` builds first).

`make clean` only removes the tags this repo applies (three to five per variant, listed above). Each
version tag is built as a derived image on top of the freshly built one, so `clean` cannot cascade-delete the
untagged `<none>` base layers left behind — they accumulate across rebuild cycles. Run `podman image prune` to clear
those; it is not run automatically here because it would also delete untagged images this repo never built.

## Continuous Integration

`.github/workflows/build.yml` builds and smoke-tests all four variants in parallel on every pull request, and
additionally publishes them on a push to `master` or a manual `workflow_dispatch`. Pull requests never receive
registry credentials and never push.

Publishing only ever happens from `master`. A manual `workflow_dispatch` run against another branch still builds
and smoke-tests that branch, but publishes nothing — the tags in this repo are mutable pointers shared by every
consumer, and a branch build must not be able to overwrite them.

There is no scheduled rebuild. The `development` variants resolve whatever 14.x pip serves at build time, and a
base-image security fix only reaches the published images when a build is triggered — so refreshing them is a
deliberate act: merge to `master`, or run the workflow from the Actions tab.

## License

This project is licensed under the GPL-3.0-or-later. The `LICENSE` file in this repo contains the bare text of the
GNU General Public License v3, which does not itself state the "or later" election — that election is made here, in
this README. Every image built from this repo carries an `org.opencontainers.image.licenses=GPL-3.0-or-later` label,
and this section is what makes that label accurate.

## Planned

The following are not implemented yet and should not be treated as available today:

- Multi-arch builds for both `amd64` and `arm64`.
