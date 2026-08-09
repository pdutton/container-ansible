# pdutton/ansible

Run Ansible without installing it — a small container image with Ansible, an SSH client, and the
usual companion Python modules, on Alpine or Ubuntu.

## Usage

Run a one-off command:

```bash
docker run --rm pdutton/ansible ansible --version
```

Alias it and use it like a local install (mounts your keys read-only and the current directory):

```bash
alias ansible='docker run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps pdutton/ansible ansible'
alias ansible-playbook='docker run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps pdutton/ansible ansible-playbook'

ansible all -i inventory -m ping
ansible-playbook -i inventory site.yml
```

Single-quote the alias so `"$PWD"` is resolved on every invocation, not once when the alias is defined.
Podman works identically — substitute `podman run`.

Use it as a base image:

```dockerfile
FROM pdutton/ansible:ubuntu-stable
COPY playbooks/ /apps/
```

## Tags

| Tag | What it is |
|---|---|
| `latest` | alias for `ubuntu-stable` |
| `ubuntu-stable`, `alpine-stable` | Ansible from the distro's packages |
| `ubuntu-development`, `alpine-development` | newer Ansible major, from pip in a venv at `/opt/ansible` |
| `ubuntu`, `alpine` | that OS's `stable` variant |
| `<os>-<major>`, `<os>-<version>` | e.g. `alpine-13`, `alpine-13.0.0` |

The Alpine variants have no WinRM or Kerberos support — use Ubuntu for Windows or Kerberos-authenticated
targets. Every tag here is mutable, including the version tags; pin by digest if you need reproducibility.

## Source

Built from [github.com/pdutton/container-ansible](https://github.com/pdutton/container-ansible) —
full documentation, Containerfiles, and CI live there. GPL-3.0-or-later.
