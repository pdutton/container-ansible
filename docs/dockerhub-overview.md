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

### Base Image

Use it as a base image:

```dockerfile
FROM pdutton/ansible:ubuntu-stable
COPY playbooks/ /apps/
```

## Useful Tags

The container image builds on two operating systems and two ansible releases at a time, yielding
four images.  The alpine variants are lightweight but lack WinRM or Kerberos support.  Use the
ubuntu variants if you need those or to extend the container when you need glibc support.

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
