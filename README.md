# container-ansible
Container Image with Ansible

## Ansible Without Installing
This repo provides a container image that allows updated versions of ansible to be run on various os versions and
variants without requiring complex installs.

### Usage Examples:
```
alias ansible="podman run -ti --rm -v ~/.ssh:/root/.ssh -v $(pwd):/apps -w /apps localhost/ansible:alpine-stable ansible"
ansible <follow command>
```

```
alias ansible-playbook="podman run -ti --rm -v ~/.ssh:/root/.ssh -v $(pwd):/apps -w /apps localhost/ansible:alpine-stable ansible-playbook"
ansible-playbook -i inventory <follow command>
```

Swap `alpine-stable` for any of the other three tags below if you need a different base OS or Ansible channel.

## Ansible Base Image
The container image provided by this repo can also be used as a base image for downstream images.

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

### Tags

Each variant produces **two tags** pointing at the same image:

- `<os>-<channel>` — e.g. `alpine-stable`, `ubuntu-development`. Stable across rebuilds; use this in scripts and
  aliases.
- `<os>-<version>` — e.g. `alpine-13.0.0`, `ubuntu-14.2.0`. Derived at build time by reading
  `ansible-community --version` out of the freshly built image, so it always reflects what's actually installed. You
  can read the same value yourself:
  ```bash
  podman run --rm localhost/ansible:alpine-stable ansible-community --version
  ```

For the `stable` variants the version tag only moves when the distro's packaged Ansible does. For the `development`
variants it moves on every build that happens to pick up a new 14.x release from pip — pip resolves whatever the
latest 14.x is at build time, so treat `alpine-14.2.0` / `ubuntu-14.2.0` as a snapshot, not a promise.

The eight tags that exist after a full build: `alpine-stable`, `alpine-development`, `ubuntu-stable`,
`ubuntu-development`, `alpine-13.0.0`, `alpine-14.2.0`, `ubuntu-13.1.0`, `ubuntu-14.2.0`.

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
make build-alpine-stable   # build just one variant
make clean                 # remove every image this repo builds
```

Run `make help` (or just `make`) to list every target, including the per-variant `build-<variant>` and
`test-<variant>` names (`test-<variant>` builds first).

## License

This project is licensed under the GPL-3.0-or-later. The `LICENSE` file in this repo contains the bare text of the
GNU General Public License v3, which does not itself state the "or later" election — that election is made here, in
this README. Every image built from this repo carries an `org.opencontainers.image.licenses=GPL-3.0-or-later` label,
and this section is what makes that label accurate.

## Planned

The following are not implemented yet and should not be treated as available today:

- A more familiar tag scheme layered on top of the current one, e.g. `latest`, `alpine`, `ubuntu`, `alpine-13`,
  `ubuntu-13`, `alpine-14`, `ubuntu-14`, and pinned patch tags like `alpine-13.8.0`.
- Multi-arch builds for both `amd64` and `arm64`.
