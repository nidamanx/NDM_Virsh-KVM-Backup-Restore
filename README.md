<a id="top"></a>

# NDM virsh KVM Backup Restore

**English** · [Italiano](README.it.md)

![Bash](https://img.shields.io/badge/bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)
![Version](https://img.shields.io/badge/version-1.2.0-informational)
![Dependencies](https://img.shields.io/badge/dependencies-libvirt%2C%20qemu--img%2C%20python3-lightgrey)

A single-script, menu-driven tool to **back up a shut-off libvirt/KVM
virtual machine, prove the backup boots, restore it, and manage the
backups**, without snapshots and without ever overwriting anything.

Version **1.2.0**, released 2026-11-20. License **AGPL-3.0-or-later**.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Interactive menu](#interactive-menu)
- [Configuration](#configuration)
- [Test boot: overlay or copy](#test-boot-overlay-or-copy)
- [Restore: original paths or a renamed copy](#restore-original-paths-or-a-renamed-copy)
- [Free space](#free-space)
- [Backups on an external disk](#backups-on-an-external-disk)
- [What a backup contains](#what-a-backup-contains)
- [Smaller backups with fstrim](#smaller-backups-with-fstrim)
- [Ownership and permissions](#ownership-and-permissions)
- [The whole cycle](#the-whole-cycle)
- [Things to watch out for](#things-to-watch-out-for)
- [Exit codes](#exit-codes)
- [Quality checks](#quality-checks)
- [Version history](#version-history)
- [Disclaimer](#disclaimer)
- [License](#license)
- [Author](#author)

---

<a id="features"></a>
## Features

- **Consistent backups only**: a VM is backed up only while shut off,
  and the backup is discarded (renamed `.INVALID`) if the VM is started
  during it or the backup stops half way. No snapshot is ever created.
- **Never guesses**: each disk is read in the format its definition
  declares, and a backup whose disks refer to other files, or whose
  folder holds files its checksums do not list, is refused.
- **Any local disk**: files, block devices (LVM) and storage-pool
  volumes, wherever they are. Each disk becomes one standalone qcow2;
  an external snapshot chain comes out flattened.
- **Everything the VM needs**: definition, disks, UEFI variables (NVRAM)
  and emulated TPM state (Windows 11 and similar guests).
- **Compressed, still usable**: each disk is compressed inside its
  qcow2 (zstd by default, lossless), so the backup takes less space and
  can still be verified and test-booted without unpacking anything.
- **Proven identical**: right after each disk is written, `qemu-img
  compare` checks that the VM sees exactly the same content as on the
  original disk; a restore is compared with the backup the same way.
- **Checksums**: every file of a backup is recorded in `SHA256SUMS` and
  checked on verify, test boot and restore.
- **Test boot**: a backup is started as a temporary, separate test VM,
  without network by default, to prove it boots. By default it boots
  the backup's own disks, opened read-only, with its changes in a small
  overlay file (no copy, starts at once); a full copy is the other
  choice. The backup is only read and re-verified afterwards, the
  original VM is never touched.
- **Safe restore**: the VM comes back with its name, UUID and network
  card, each disk to its original path and file name; or as a renamed
  copy next to the original. Every target is shown before a typed
  `yes`, nothing existing is ever overwritten, and the VM is not started.
- **Free space shown first**: every write shows the space it needs, is
  refused without room, and asks when it would leave the disk nearly
  full.
- **Safe delete**: only folders shaped like a backup are deleted, with a
  warning when it is the last backup of that VM.
- **Interactive menu** with a session backups folder, or plain commands
  for scripts.
- **Configuration file** read as data, never executed, editable from
  the menu.
- **Works in any language**: libvirt messages are read in the C locale.

[Back to top](#top)

---

<a id="requirements"></a>
## Requirements

| Requirement | Debian/Ubuntu | Fedora/RHEL | Arch | Why |
|---|---|---|---|---|
| bash 4.4 or later | `bash` | `bash` | `bash` | the script itself |
| `virsh` | `libvirt-clients` | `libvirt-client` | `libvirt` | VM definitions, states, define/undefine |
| `qemu-img` 2.10 or later, 5.1 or later for zstd | `qemu-utils` | `qemu-img` | `qemu-img` | disk conversion, compression, comparison and size estimate |
| `python3` | `python3` | `python3` | `python` | reading and rewriting the XML definition |
| root, through `sudo` | `sudo` | `sudo` | `sudo` | disk images, NVRAM and TPM state |
| `setfacl`, `getfacl` (overlay test boot only) | `acl` | `acl` | `acl` | letting the hypervisor's user into the backup folder during the test |

All at once:

```bash
# Debian, Ubuntu
sudo apt install libvirt-clients qemu-utils python3 sudo acl
# Fedora, RHEL and derivatives
sudo dnf install libvirt-client qemu-img python3 sudo acl
# Arch, Manjaro
sudo pacman -S --needed libvirt qemu-img python sudo acl
```

On a host that already runs VMs with virt-manager, most of them are
installed. At every start the script checks the commands it cannot
work without and, if one is missing, stops with the install command for
the distribution it runs on (read from `/etc/os-release`); it never
installs anything itself. `setfacl`/`getfacl` are checked only before
an overlay test boot.

Standard tools (`coreutils`, `findutils`, `util-linux`, `gawk`/`mawk`,
`sed`) are expected to be present. The VMs are the system ones of libvirt
(`qemu:///system`), as managed by virt-manager.

Started without root from a terminal, the script says so and runs
itself again through `sudo`, which asks for the password and refuses a
user it does not allow. When that run ends, also through Ctrl-C or a
closed terminal, it drops the cached `sudo` credentials (`sudo -k`):
the next `sudo` on that terminal asks for the password again, even if
one was cached before the script started. Without a terminal (a cron
job, a pipe) it only stops.

[Back to top](#top)

---

<a id="quick-start"></a>
## Quick start

The project is one folder: the script, its configuration and, by
default, the backups (`backup/`). Put it wherever you like: on the
backup disk itself, so the backups stay next to the tool that made
them and the disk works the same on any host, or in a folder such as
`/opt`. Only the folder holds anything of the tool; the VMs stay where
they are.

```bash
# On the backup disk (see "Backups on an external disk")
sudo cp -r ndm_virsh-kvm-backup-restore /mnt/vm-backup/
sudo /mnt/vm-backup/ndm_virsh-kvm-backup-restore/ndm_virsh-kvm-backup-restore.sh

# Or in /opt, with an optional link in the PATH
sudo cp -r ndm_virsh-kvm-backup-restore /opt/
sudo ln -s /opt/ndm_virsh-kvm-backup-restore/ndm_virsh-kvm-backup-restore.sh /usr/local/bin/
sudo ndm_virsh-kvm-backup-restore.sh
```

Without arguments the script opens the menu. With the defaults,
backups go to `backup/` inside the project folder. `BACKUP_DIR` (menu
`s`) puts them elsewhere: keep them off the system disk and off the
disk the VMs live on, ideally on encrypted storage. The first change
creates `ndm_virsh-kvm-backup-restore.conf` from the shipped
`.conf.example`. A link in the `PATH` must be a link, not a copy: the
script finds its configuration next to its real location.

Some ways of copying the folder drop the executable bit: an editor's
download (VS Code's "Download..."), a zip, many graphical SFTP clients.
`git clone`, `rsync -a` and `scp -p` keep it. If `sudo
./ndm_virsh-kvm-backup-restore.sh` answers "command not found" or
"Permission denied", give it back once:

```bash
chmod +x ndm_virsh-kvm-backup-restore/ndm_virsh-kvm-backup-restore.sh
```

[Back to top](#top)

---

<a id="usage"></a>
## Usage

```text
# Interactive menu
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE]

# Command mode (no menu, for scripts)
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] save DOMAIN [DEST_DIR]
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] verify BACKUP_DIR
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] test-start BACKUP_DIR [--overlay|--copy] [--with-network] [--test-dir DIR]
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] test-clean DOMAIN
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] restore BACKUP_DIR [DISK_DIR] [--copy]
sudo ndm_virsh-kvm-backup-restore.sh [-c FILE] delete BACKUP_DIR

# Help and version (no sudo needed)
ndm_virsh-kvm-backup-restore.sh -h | --help
ndm_virsh-kvm-backup-restore.sh -V | --version
```

`DOMAIN` is the VM name as shown by virt-manager or `virsh list --all`.
`BACKUP_DIR` is a folder made by `save`: `DEST_DIR/DOMAIN-<date>-<time>`.

### Commands

| Command | What it does |
|---|---|
| `save DOMAIN [DEST_DIR]` | Backs up a shut-off VM into a new folder `DEST_DIR/DOMAIN-<date>-<time>`. Without `DEST_DIR`, the `BACKUP_DIR` of the configuration in use. A missing destination is created, an existing one is used as it is; if a backup with the same name is already there, nothing is done. Free space is checked first. |
| `verify BACKUP_DIR` | Checks every file of a backup against `SHA256SUMS`, and that the folder holds no file `SHA256SUMS` does not list. |
| `test-start BACKUP_DIR [--overlay\|--copy] [--with-network] [--test-dir DIR]` | Starts the backup as the test VM `zztest-restore-DOMAIN` (prefix set by `TEST_PREFIX`), marked as a test VM in its libvirt description. `--overlay` (default, `TEST_MODE`) boots the backup's own disks read-only, `--copy` a copy of them: see [Test boot](#test-boot-overlay-or-copy). Its files go into `DIR/zztest-restore-DOMAIN/` (default `TEST_BASE_DIR`, else next to the original disks). No network unless `--with-network`, which is refused while the original VM runs. The test VM never gets the original's passthrough host devices or host folder shares. |
| `test-clean DOMAIN` | Stops and removes the test VM of `DOMAIN` and its files. Refused for a VM without the test marker, whatever its name. After an overlay test it gives the backup's disks back to the owner they had before, `0600`, removes the access it gave the hypervisor's user, and re-verifies the backup. Never touches the original VM. |
| `restore BACKUP_DIR [DISK_DIR] [--copy]` | Defines the VM again from the backup, with its name, UUID and network card, each disk back to its original path and file name. With `--copy`, a renamed copy `restore-DOMAIN` (prefix `RESTORE_PREFIX`) with a new UUID and MAC address, disks `restore-<file name>` next to the originals. `DISK_DIR` puts the disks there instead, under their original names. Shows every target and asks for `yes`; any existing target stops it. The VM is not started. See [Restore](#restore-original-paths-or-a-renamed-copy). |
| `delete BACKUP_DIR` | Deletes one backup after asking to type `yes`. |

### Options

| Option | Description |
|---|---|
| `-c FILE`, `--config FILE` | Use `FILE` instead of the configuration next to the script. |
| `-h`, `--help` | Full help, with every command, the configuration and an example. |
| `-V`, `--version` | Version, release date, copyright and license. |

[Back to top](#top)

---

<a id="interactive-menu"></a>
## Interactive menu

Run the script without a command:

```text
NDM virsh KVM Backup Restore 1.2.0 - KVM virtual machine backups
  Backups folder: /mnt/vm-backup/ndm_virsh-kvm-backup-restore/backup
  Configuration:  /mnt/vm-backup/ndm_virsh-kvm-backup-restore/ndm_virsh-kvm-backup-restore.conf

  1) Back up a VM                           (save)
  2) Verify a VM backup                     (verify)
  3) Test-boot a VM backup                  (test-start)
     starts a temporary test VM from the backup (overlay or copy);
     the backup is only read, the original VM is not touched
  4) Remove the test VM started by 3        (test-clean)
     deletes only the temporary test VM and its files
  5) Restore a VM from its backup           (restore)
     back to its original disk paths, same name and identity
  6) Restore as a renamed copy              (restore --copy)
     restore-<vm>, new identity, next to the original
  7) Delete a VM backup                     (delete)
  f) Change the backups folder for this session
  s) Settings (saved in the configuration file)
  h) Show the help
  v) Show the version
  q) Quit
```

- **Back up** lists every VM with its state. Running ones are shown
  too, marked "shut it down first", and refused if chosen. The space
  needed is shown before the confirmation.
- **Verify, test boot, restore, delete** list the backups of the
  backups folder, newest first, with their size, marking the ones
  whose VM still exists.
- **Test boot** asks for the test folder (Enter: `TEST_BASE_DIR`, else
  next to the original disks), then for the mode, showing for both the
  space needed and free, and whether the overlay is possible there:

  ```text
  | Test mode (Enter for o, from TEST_MODE):
  | o) overlay  boots the backup's own disks, read-only;
  |            what the test VM writes goes to a small file
  |            space: about 1.0GiB in /home/shared/VMs/kvm (120.0GiB free)
  |            backup reachable by the hypervisor: yes
  | c) copy     boots a copy of the backup, which is only read once
  |            space: about 48.2GiB in /home/shared/VMs/kvm (120.0GiB free)
  ```

  An overlay that is not possible is marked with the reason and cannot
  be chosen; the script never switches mode by itself.
- **Restore** (5) and **restore as a renamed copy** (6) ask for a disk
  folder only when an original one does not exist on this host, then
  show every file they will write and ask for `yes`.
- After each action, Enter brings the menu back. Inside an action, `q`
  goes back to the menu; in the main menu it quits.
- The backups folder comes from the configuration; `f` changes it for
  the current session only, `s` changes the configuration.

[Back to top](#top)

---

<a id="configuration"></a>
## Configuration

The configuration file has the script's name with `.conf` and sits in
the script's own folder, even when the script is run through a link.
`-c FILE` uses another one. A missing file or key takes the default.

The project ships `ndm_virsh-kvm-backup-restore.conf.example`, with
every key, its default and a comment. The real `.conf` is kept out of
git: copy the example to it and edit it, or let the menu (`s`) create
it from the example at the first change.

The file is **read as data, never executed**: one `KEY=value` per line,
`#` for comments, the value optionally in quotes. Values containing
quotes, backslashes, `$` or backticks are refused, and so are unknown
keys, with the line number. The menu (`s`) changes one setting at a
time and keeps the comments. Switching `BACKUP_OWNER` to `user` there
shows its dangers first and needs a typed `yes`.

| Key | Default | Description |
|---|---|---|
| `BACKUP_DIR` | `./backup` | Folder for the backups. A relative path starts at the configuration file's folder; `~` is the home of the user who ran `sudo`. The default `backup/` ships with the project (its content is git-ignored); any other folder is created, after asking, at the first backup. |
| `BACKUP_OWNER` | `user` | `user`: the whole backup, VM disks included, belongs to the user who ran `sudo` and is readable without `sudo`. `root`: everything is root's. Read the dangers in [Ownership and permissions](#ownership-and-permissions) before choosing. |
| `COMPRESS` | `zstd` | Compression inside each backup disk's qcow2: `zstd` (QEMU 5.1 or later), `zlib` (older QEMU) or `none`. Lossless. The backup stays directly usable; restore writes the disks back uncompressed. |
| `COMPARE` | `yes` | `yes`: after each disk is written, `qemu-img compare` proves the VM sees the same content as on the original, and any difference marks the backup `.INVALID`. It reads both disks in full, so it about doubles the backup time. `no`: skip it. |
| `LIBVIRT_URI` | `qemu:///system` | libvirt connection, local only: `qemu:///system` or `qemu:///session` (other transports can make libvirt run a command). Not a disk location: disks are found from each VM's definition. |
| `TEST_PREFIX` | `zztest-restore-` | Name prefix of the test VM. Letters, digits, `.`, `_` and `-`, ending with `-`. Test VMs also carry a marker in their libvirt description, and only marked VMs are ever removed, so a real VM whose name starts with the prefix is safe. Remove existing test VMs before changing it: the menu lists only the ones with the current prefix. |
| `TEST_BASE_DIR` | (empty) | Parent folder of the test VM's files. Empty: next to the original VM's disks, else the `default` pool's folder, else `/var/lib/libvirt/images`. The menu asks at each test with this as the default; `--test-dir` overrides it on the command line. |
| `TEST_NETWORK` | `no` | Default answer in the menu to "start the test VM with a network card?". `no`: no network, so the original VM can keep running at the same time. `yes`: same network as the original, refused while it runs. |
| `TEST_MODE` | `overlay` | Default test-boot mode: `overlay` (the backup's own disks, read-only) or `copy`. See [Test boot](#test-boot-overlay-or-copy). |
| `RESTORE_PREFIX` | `restore-` | Prefix of the VM name and disk file names of a restore as a renamed copy. Letters, digits, `.`, `_` and `-`, ending with `-`. |

[Back to top](#top)

---

<a id="test-boot-overlay-or-copy"></a>
## Test boot: overlay or copy

A test boot proves that the **backup** boots: the original VM already
does. With `save` (the backup has the same content as the original,
`qemu-img compare`) and `restore` (the restored disk has the same
content as the backup, compared the same way), it closes the chain of
proof.

In both modes the backup's content is never written: it is only read.

| | Overlay (default) | Copy |
|---|---|---|
| What boots | the backup's own disks, opened read-only; what the test VM writes goes into a small overlay file | a copy of the backup's disks |
| Space in the test folder | about 1 GiB, growing with what the test VM writes | the backup's size, growing too |
| Start | at once | after copying the whole backup |
| Backup's disk during the test | must stay connected | needed only for the copy |
| Speed of the test VM | reads the backup (slower on a USB disk) | reads the test folder |
| Where the backup may be | the hypervisor's user must pass through every folder above it | anywhere |

How the overlay reaches the backup: QEMU runs as its own user
(`libvirt-qemu` on Debian). libvirt hands it the disk files while the
VM runs, but never changes folders. So:

- the **backup folder** itself (`0750` with `BACKUP_OWNER=user`): the
  script gives that user a pass-through ACL on it for the test, and
  `test-clean` removes it;
- **every folder above it** must already let that user through (an `x`
  for others in `ls -ld`, or `namei -l <backup folder>` for the whole
  path). The script checks it first, names the folder that blocks, and
  never changes a folder it did not create. A folder next to the VMs'
  disks always works, since the VMs already run from there. Common
  blockers: a home folder that is `0700` or `0750`, and a disk the
  desktop mounted under `/media/<user>/` (see
  [Backups on an external disk](#backups-on-an-external-disk)).

After an overlay test, `test-clean` gives the backup's disks back to
the owner they had before the test, `0600` (libvirt gives them back too
when the VM stops, but a power
cut during the test can leave them with its user), removes the ACL, and
re-verifies the backup against `SHA256SUMS`, as proof that it is
unchanged. If the backup's disk is not connected then, it says what to
run when it is back.

If `test-start` fails or is interrupted (Ctrl-C, closed terminal)
before the test VM exists, it removes its folder and undoes the ACL
itself; if a step of that undo fails, it prints the commands to finish
it by hand. Only `kill -9` or a power cut skips it.

The overlay needs the backup folder named as `save` names it
(`<vm>-<date>-<time>`), and the test folder's parent reachable by the
hypervisor's user too; otherwise the menu marks it as not possible and
says why.

[Back to top](#top)

---

<a id="restore-original-paths-or-a-renamed-copy"></a>
## Restore: original paths or a renamed copy

| | `restore` (menu 5) | `restore --copy` (menu 6) |
|---|---|---|
| VM | its original name, UUID and network card | `restore-<name>` (`RESTORE_PREFIX`), new UUID and MAC address |
| Disks | back to their original path: same folder, same file name | next to the originals, as `restore-<file name>` |
| Use | the real restore, once the broken VM is gone | comparing the backup with the original, side by side |
| Refused when | a VM with that name or UUID is defined, or a target file exists | a VM with the copy's name is defined, or a target file exists |

For example, a VM whose disk is `/home/shared/VMs/kvm/MYVM.qcow2`:

- `restore` writes `/home/shared/VMs/kvm/MYVM.qcow2` and defines `MYVM`.
  If the old file is still there, the restore stops: rename it (for
  example to `MYVM.qcow2.broken`) or remove it first, or use `--copy`.
- `restore --copy` writes `/home/shared/VMs/kvm/restore-MYVM.qcow2` and
  defines `restore-MYVM`. Inside, the copy still has the original's
  hostname, IP address and keys: do not run both on the same network.

Before writing anything, the script shows every file it will write and
asks for `yes`. Nothing existing is ever overwritten. Since it runs as
root and the paths come from the backup, each original folder must
exist, be an absolute path and hold no link.

**On another host** (the original folder does not exist): the script
says so and stops. Give a folder for the disks, `restore BACKUP_DIR
DISK_DIR` (the menu asks for it): the disks keep their original file
names there.

Disks that were block devices (LVM) or pool volumes come back as files
named `<name>-<dev>.qcow2`, in `DISK_DIR` or next to the first disk.

[Back to top](#top)

---

<a id="free-space"></a>
## Free space

Backup, test boot and restore show, before writing anything, the space
needed and free on each disk they write to:

- not enough room for the need plus 10%: nothing is done, and the
  message says what to change (another folder, `BACKUP_DIR`,
  `--test-dir` or `TEST_BASE_DIR`, `DISK_DIR`);
- enough room, but less than 10% of that disk would stay free: the
  script warns and asks to type `yes`. When a disk fills up, libvirt
  pauses the running VMs with disks on it: a test copy next to the VMs'
  disks can stop the original VM itself. Without a terminal it stops.

The backup's estimate is the uncompressed size, so the backup usually
takes less. A test VM's files grow while it runs: keep tests short.

[Back to top](#top)

---

<a id="backups-on-an-external-disk"></a>
## Backups on an external disk

A backup on the same disk as the VMs does not survive that disk: fine
for a quick first copy, not as the only one. An external disk works
best with the whole project folder on it (see
[Quick start](#quick-start)).

- **Filesystem: ext4 inside LUKS encryption.** Encryption is what
  protects a lost or stolen disk: owners and modes do not (see
  [Ownership and permissions](#ownership-and-permissions)). Not exFAT
  or NTFS: they have no owners or permissions, so every user of the
  host could read the backups' disks, and TPM state loses its owner.
- **A fixed mount point**, not the desktop's automatic one. The desktop
  mounts disks under `/media/<user>/<label>/`; `/media/<user>` lets
  only that user in, so an overlay test cannot reach the backup, and
  the path changes with the label. A line in `/etc/fstab` with the
  disk's UUID gives a stable path and permissions that depend only on
  the disk itself:

  ```text
  # find the UUID with: lsblk -f
  UUID=<uuid>  /mnt/vm-backup  ext4  defaults,nofail,noatime  0  2
  ```

  `nofail` lets the host boot without the disk. With LUKS, add a line
  to `/etc/crypttab` and use the opened device's UUID instead. Do not
  add `noexec`: the script on the disk would not run.
- **Permissions on the disk**: a freshly made ext4 has its top folder
  `root 0755`, which lets the hypervisor's user through; folders you
  create on it keep the usual `0755`. The backup folders themselves
  stay `0750`/`0700`: the overlay test opens them with an ACL only for
  its duration (ext4 supports ACLs without extra options).

A libvirt storage pool on the backup folder is not needed and not
advised: it does not change folder permissions, and it shows the
backup's disks in virt-manager as volumes that can be deleted or
attached by mistake.

[Back to top](#top)

---

<a id="what-a-backup-contains"></a>
## What a backup contains

```text
myvm-20261018-141829/
  domain.xml            VM definition (without console passwords)
  disk-vda.qcow2        one standalone qcow2 per disk, compressed inside
  disk-vda.info.txt     qemu-img info of the original disk
  nvram.fd              UEFI variables (UEFI VMs only)
  tpm/                  emulated TPM state (only if the VM has one)
  sources.txt           where each file came from
  SHA256SUMS            checksums of all of the above
```

Console (VNC/SPICE) passwords are not saved: set them again after a
restore if you use them.

[Back to top](#top)

---

<a id="smaller-backups-with-fstrim"></a>
## Smaller backups with fstrim

When a file is deleted inside the VM, the guest marks its blocks as
free, but the virtual disk does not know: those blocks still hold the
old data and are copied into every backup. Telling the disk which
blocks are free makes the backup smaller, often by more than
compression does.

Inside the VM, just before shutting it down for a backup:

```bash
sudo fstrim -av     # Linux: trims every mounted filesystem, prints how much
sudo poweroff
```

On Windows guests, Optimize Drives (`defrag C: /L` from an
administrator prompt) does the same.

It works when the virtual disk passes discard requests through: in
virt-manager, the disk's Performance options with Discard mode set to
`unmap` (`discard='unmap'` in the disk's `<driver>`), on a `virtio-scsi`
or `virtio` (VirtIO, recent QEMU) bus. If `fstrim` reports
"the discard operation is not supported", the disk does not pass it
through and the trim has no effect on the backup. Running it is
harmless either way.

[Back to top](#top)

---

<a id="ownership-and-permissions"></a>
## Ownership and permissions

With `BACKUP_OWNER=user`, `USER` being the one who ran `sudo`:

| What | Owner | Mode |
|---|---|---|
| Backup folder, and a backups folder the script creates | `USER` | `0750` |
| `domain.xml`, `sources.txt`, `*.info.txt`, `SHA256SUMS` | `USER` | `0640` |
| `disk-*.qcow2`, `nvram.fd` | `USER` | `0600` |
| `tpm/` | as the original | as the original |

With `BACKUP_OWNER=root`, or when run as root without `sudo`, every row
but `tpm/` becomes root: folders `0700`, files `0600`.

A backups folder that already exists is never changed.

### What the owner protects, and what it does not

Owners and modes only count on the host that applies them. Whoever has
the backup's disk in hand mounts it on a machine where they are root,
and reads everything, whatever the owners say. **Against a lost or
stolen disk, only encryption protects: keep the backups, and every copy
of them, on LUKS.** That holds with both values of `BACKUP_OWNER`.

On the running host, the owner decides which programs can read the VM
disks without `sudo`:

- **`BACKUP_OWNER=user`**: user-level tools work on the whole backup,
  disks included. A backup tool running as `USER` (Back In Time, for
  instance) can copy the backups to another disk. **The danger**: so
  can anything else running as `USER`. A malicious browser extension,
  a compromised program, a sync client (Nextcloud, Dropbox) that
  uploads the folder, or a backup tool that copies it to storage that
  is not encrypted all get every key, password and secret stored on
  the VMs, without `sudo` and without any prompt.
- **`BACKUP_OWNER=root`**: reading the disks needs `sudo` or a tool
  running as root (for instance Back In Time in its root mode, which
  keeps the owners). A program running as `USER` cannot read them
  directly. That barrier is a weak one: a program that controls the
  user's session can wait for the `sudo` password. It stops casual
  leaks, not a determined attacker.

Choose `root` if nothing running as `USER` needs to read the backups.

Backups made by 1.1.0 or earlier have root-owned disks and NVRAM. To
give them to `USER`, as 1.2.0 does with `BACKUP_OWNER=user`:

```sh
sudo chown USER: /path/to/backup/*/disk-*.qcow2 /path/to/backup/*/nvram.fd
```

### Restored and test disks

Restored disks and the test VM's disks are root `0600`, like the ones
virt-manager creates, whatever `BACKUP_OWNER` says: libvirt gives them
to its own user while the VM runs and takes them back when it stops.
During an overlay test the same happens to the backup's disks, and the
backup folder gets a pass-through ACL for that user; `test-clean` gives
the disks back to the owner they had before the test and removes the
ACL.

[Back to top](#top)

---

<a id="the-whole-cycle"></a>
## The whole cycle

The same steps are available from the menu (options 1 to 6).

```bash
# 0. Inside the VM: free the space of deleted files, then shut it down
sudo fstrim -av
sudo poweroff

# 1. Back up
sudo ndm_virsh-kvm-backup-restore.sh save myvm /mnt/backup
#    or, into BACKUP_DIR of the configuration:
#    sudo ndm_virsh-kvm-backup-restore.sh save myvm
#    -> /mnt/backup/myvm-20261018-141829

# 2. Verify the backup
sudo ndm_virsh-kvm-backup-restore.sh verify /mnt/backup/myvm-20261018-141829

# 3. Prove it boots, then remove the test VM
sudo ndm_virsh-kvm-backup-restore.sh test-start /mnt/backup/myvm-20261018-141829
#    (overlay by default; --copy for a copy, --test-dir DIR for its files)
#    virt-manager: open zztest-restore-myvm (TEST_PREFIX + name),
#    log in from the console, shut it down
sudo ndm_virsh-kvm-backup-restore.sh test-clean myvm

# ... later, the VM is lost or broken ...

# 4. Verify the backup again before using it
sudo ndm_virsh-kvm-backup-restore.sh verify /mnt/backup/myvm-20261018-141829

# 5. Remove what is left of the broken VM, if anything
#    virt-manager: right click, Delete (or: sudo virsh undefine myvm),
#    and rename or remove its old disk file (restore never overwrites it)

# 6. Restore it, to its original disk paths
sudo ndm_virsh-kvm-backup-restore.sh restore /mnt/backup/myvm-20261018-141829
#    or, keeping the original, as restore-myvm next to it:
#    sudo ndm_virsh-kvm-backup-restore.sh restore /mnt/backup/myvm-20261018-141829 --copy
#    or, on a host without the original folder:
#    sudo ndm_virsh-kvm-backup-restore.sh restore /mnt/backup/myvm-20261018-141829 /srv/vms

# 7. Start it and check it; the backup stays usable for the next time
sudo virsh start myvm
sudo ndm_virsh-kvm-backup-restore.sh verify /mnt/backup/myvm-20261018-141829
```

[Back to top](#top)

---

<a id="things-to-watch-out-for"></a>
## Things to watch out for

- **A backup holds the whole VM**: every key, password and secret
  stored in it. Keep backups, and every copy of them, on encrypted
  storage only; with `BACKUP_OWNER=user` any program running as you can
  read them (see
  [Ownership and permissions](#ownership-and-permissions)). Never
  commit them (the shipped `.gitignore` excludes everything in
  `backup/` except its `.gitkeep`).
- **Shut the VM down from inside** (or Shut Down in virt-manager)
  before a backup. Force Off is a power cut: the backup is then
  consistent only as after a crash.
- **The test VM is a clone**: same IP address, keys and scheduled jobs
  as the original. Without network it cannot clash with it; with
  `--with-network`, keep the original shut off until `test-clean`. The
  same holds for a restore with `--copy`.
- **Keep the backup's disk connected during an overlay test**: if it
  goes away, the test VM stops; the backup itself is not damaged, it is
  only read.
- **Internal snapshots are not backed up**, only the current state of
  each disk.
- **Damage to a compressed backup costs more**: a bad spot on the
  storage loses one compressed block (64 KiB) instead of a few bytes.
  `verify` detects both; keep more than one backup and verify them from
  time to time. Set `COMPRESS=none` if that trade-off does not suit you.
- **Compression gain depends on the content**: large on system disks,
  close to nothing on data that is already compressed (video, archives).
  See [Smaller backups with fstrim](#smaller-backups-with-fstrim).
- **The script runs as root**: whoever can edit the script itself can
  run commands as root. Keep the project folder owned by root if other
  users can log in. The configuration file is safe to leave writable:
  it is never executed.
- **Members of the `libvirt` group** can already reach every VM disk
  through libvirt: if `USER` is one of them, giving them the backups
  (`BACKUP_OWNER=user`) does not widen what that account can read on
  that host. It does widen it for programs running as `USER` that do
  not go through libvirt (see
  [Ownership and permissions](#ownership-and-permissions)).

[Back to top](#top)

---

<a id="exit-codes"></a>
## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, or nothing done on purpose (answer `q`, confirmation refused) |
| `1` | Any error: wrong arguments, refused action, failed check; the reason is on stderr |

[Back to top](#top)

---

<a id="quality-checks"></a>
## Quality checks

```bash
shellcheck ndm_virsh-kvm-backup-restore.sh
bash -n ndm_virsh-kvm-backup-restore.sh
```

Both run clean on every release. The CI runs them on every push, with
smoke tests of the command line (help, version, invalid usage, a
configuration file that must never be executed) and a check that the
version is the same in the script, both READMEs, `CHANGELOG.md` and
`CITATION.cff`.

[Back to top](#top)

---

<a id="version-history"></a>
## Version history

Every release, with what changed for the user: [CHANGELOG.md](CHANGELOG.md).

[Back to top](#top)

---

<a id="disclaimer"></a>
## Disclaimer

> This software reads and writes virtual machine disks as root. It never
> overwrites an existing file and deletes only what the documentation
> above describes, but a backup is only as good as the last time it was
> verified and test-booted. Test your backups. The software is provided
> without any warranty, to the extent permitted by law.

[Back to top](#top)

---

<a id="license"></a>
## License

Copyright (C) 2026 Nicola Davide Mannarelli - @nidamanx

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version. See [LICENSE](LICENSE) or
<https://www.gnu.org/licenses/agpl-3.0.html>.

When you distribute this software, include the full license text.

[Back to top](#top)

---

<a id="author"></a>
## Author

Nicola Davide Mannarelli (@nidamanx)

[Back to top](#top)
