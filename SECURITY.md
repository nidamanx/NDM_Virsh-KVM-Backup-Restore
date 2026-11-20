# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use the
private vulnerability reporting of the repository's hosting platform
(the Security tab on GitHub, a confidential issue on GitLab), and
include:

- the script version (`ndm_virsh-kvm-backup-restore.sh -V`);
- the distribution, and the libvirt and QEMU versions;
- the steps to reproduce the problem;
- the expected impact.

This is a personal project maintained on a best-effort basis. Fixes are
released before any public disclosure.

## Scope

In scope:

- a backup, test boot, restore or delete that reads, writes, overwrites
  or deletes anything outside what the README documents;
- a configuration file that can make the script run code or commands
  (it is read, never executed, and runs as root);
- backup files readable by users other than the documented owner;
- a checksum check that accepts a modified backup.

Out of scope:

- anyone who can already run commands as root, or who is in the
  `libvirt` group (that access is already equivalent to root on the
  host);
- the content of a backup once copied elsewhere by the operator: a
  backup holds every secret stored in the VM, and keeping it on
  encrypted storage is the operator's responsibility;
- weaknesses in libvirt, QEMU or the guest operating system.
