# pdutton/ansible

Run Ansible without installing it — a small container image with Ansible, an SSH client, and the
usual companion Python modules, on Alpine or Ubuntu.

## Usage

### As a Command

To use it as a drop in replacement for ansible commands, alias it and use it like a local install
(mounts your keys read-only and the current directory):

```bash
alias ansible='docker run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps pdutton/ansible ansible'
alias ansible-playbook='docker run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps pdutton/ansible ansible-playbook'

ansible all -i inventory -m ping
ansible-playbook -i inventory site.yml
```

The container runs as root, so `ssh` logs in to remote hosts as `root` unless told otherwise. Add a
`Host *` block with `User your-username` at the **end** of `~/.ssh/config` to make your own user
the default; per-host `User` entries earlier in the file still win.

With rootful Docker (the Linux default), the mounted `~/.ssh/config` is owned by your uid rather
than root, and `ssh` refuses to read it (`Bad owner or permissions on /root/.ssh/config`). Use
rootless Docker or Podman if you rely on an SSH config.

### Base Image

Use it as a base image:

```dockerfile
FROM pdutton/ansible:ubuntu-stable
COPY playbooks/ /apps/
```

## Useful Tags

The container image builds on two operating systems and two ansible releases at a time, yielding
four images.  All four can manage Windows hosts over PSRP (`ansible_connection: psrp`) with
NTLM, Basic, CredSSP, or certificate auth.  The alpine variants are lightweight but lack WinRM
and Kerberos support.  Use the ubuntu variants if you need those (mount your own
`/etc/krb5.conf`) or to extend the container when you need glibc support.

Every variant also bundles the
[`pdutton.xplat`](https://github.com/pdutton/ansible-collection-xplat) collection, which
provides cross-platform modules and path filters that dispatch to the Linux or Windows
implementation as appropriate.

| Tag | Aliases |
|-----|---------|
| `alpine-stable`      | `alpine` |
| `alpine-development` |          |
| `ubuntu-stable`      | `latest`, `ubuntu` |
| `ubuntu-development` |                    |

## Source

Built from [github.com/pdutton/container-ansible](https://github.com/pdutton/container-ansible) —
full documentation, Containerfiles, and CI live there.

## Intended Audience

Feel free to use this container image for personal use or learning ansible.
If you create useful container images based off of this image, please share the code
you used to produce it so everyone can benefit.
This container image is not intended for commercial use.

The container image and code is licensed under GPL-3.0-or-later
