# container-ansible
Container Image with Ansible

## Ansible Without Installing
This repo provides a container image that allows updated versions of ansible to be run on various os versions and
variants without requiring complex installs.

### Usage Examples:
```
alias ansible="docker run -ti --rm -v ~/.ssh:/root/.ssh -v $(pwd):/apps -w /apps alpine/ansible ansible"
ansible <follow command>
```

```
alias ansible-playbook=" docker run -ti --rm -v ~/.ssh:/root/.ssh -v $(pwd):/apps -w /apps alpine/ansible ansible-playbook"
ansible-playbook -i inventory < follow command>
```

## Ansible Base Image
The container image provided by this repo can also be used as a base image for downstream images.

## Image Variants
The ability to build this image using various base images (alpine, ubuntu-minimal, ?) will be provided using
build args.

## Tags
Example planned tags:
  - latest (same as alpine)
  - alpine (latest stable alpine base, latest stable ansible)
  - ubuntu (latest stable ubuntu base, latest stable ansible)
  - alpine-14 (alpine base, latest ansible 14.y.z)
  - ubuntu-14 (ubuntu base, latest ansible 14.y.z)
  - alpine-13 (alpine base, latest ansible 13.y.z)
  - ubuntu-13 (ubuntu base, latest ansible 13.y.z)
  - alpine-13.8.0 (alpine base, ansible 13.8.0)
  - ubuntu-13.8.0 (ubunut base, ansible 13.8.0)

## Wishlist
Build for both arm64 and amd64

