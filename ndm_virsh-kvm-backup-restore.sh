#!/bin/bash
# ndm_virsh-kvm-backup-restore.sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Nicola Davide Mannarelli - @nidamanx
#
# Offline backup of any libvirt/KVM virtual machine (definition, local
# disks, NVRAM, TPM state), a disposable test boot of such a backup, and
# the restore of the VM from it. Runs on the hypervisor host, as root.
# Full usage: ndm_virsh-kvm-backup-restore.sh --help.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License along with this program. If not, see
# <https://www.gnu.org/licenses/>.
#
# Design notes (the why; the what is in usage() below):
# - Only a shut-off VM is backed up: a running guest's disk is consistent
#   only at crash level, and no snapshot is ever taken.
# - Disks are written by qemu-img convert as one standalone qcow2 each,
#   whatever they were (file, block device, pool volume): one format to
#   restore, and an external snapshot chain comes out flattened. The
#   file is never byte-identical to the original (the container is
#   rewritten, compressed or not), so identity is proven on the content
#   the guest sees, with qemu-img compare, not with a file checksum.
# - The test VM has no network by default: a clone keeps the original's
#   IP, keys and scheduled jobs, so on the same network it would clash
#   with the original and act as it.
# - restore never overwrites anything and never starts the VM: putting
#   a VM back is the operator's decision, the script only refuses the
#   unsafe cases.
set -euo pipefail
umask 077
# virsh translates domain states ("shut off" is "terminato" in Italian),
# and the checks below compare them as text.
export LC_ALL=C

APP_TITLE="NDM virsh KVM Backup Restore"
APP_VERSION="1.2.0"
APP_RELEASE_DATE="2026-11-20"
APP_AUTHOR="Nicola Davide Mannarelli - @nidamanx"
APP_LICENSE="AGPL-3.0-or-later"

# The configuration file sits next to the real script (a link in
# /usr/local/bin is followed) and shares its name: -c overrides it.
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
CONFIG_FILE="${SCRIPT_PATH%.sh}.conf"

# Defaults, used for any key the configuration file does not set.
CONF_KEYS=(BACKUP_DIR BACKUP_OWNER COMPRESS COMPARE LIBVIRT_URI TEST_PREFIX TEST_BASE_DIR TEST_NETWORK TEST_MODE RESTORE_PREFIX)
BACKUP_DIR="./backup"
BACKUP_OWNER="user"
COMPRESS="zstd"
COMPARE="yes"
LIBVIRT_URI="qemu:///system"
TEST_PREFIX="zztest-restore-"
TEST_BASE_DIR=""
TEST_NETWORK="no"
TEST_MODE="overlay"
RESTORE_PREFIX="restore-"

VIRSH=(virsh -c "$LIBVIRT_URI")
# Description given to every test VM: test-clean and the menu act only
# on a domain carrying it, whatever TEST_PREFIX is, so a real VM whose
# name happens to start with the prefix is never touched.
TEST_MARKER="Temporary test VM made by ndm_virsh-kvm-backup-restore.sh from a backup: remove it with test-clean."
SWTPM_DIR=/var/lib/libvirt/swtpm
NVRAM_DIR=/var/lib/libvirt/qemu/nvram
# Folder name save gives a backup (DOMAIN-YYYYMMDD-HHMMSS, .INVALID if
# the VM started during it): the only shape delete ever removes.
BACKUP_NAME_RE='^[A-Za-z0-9._-]+-[0-9]{8}-[0-9]{6}(\.INVALID)?$'
# Room counted for an overlay test: it holds only what the test VM
# writes, which no one can know in advance.
OVERLAY_ROOM=$((1024 * 1024 * 1024))
# Written by test-start in the test folder: mode, backup, ACL state, so
# test-clean can undo exactly what test-start did to the backup folder.
TEST_INFO=test-info.txt

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi
ok()   { printf '%b\n' "${C_GREEN}OK${C_RESET} $*"; }
info() { printf 'i  %s\n' "$*"; }
err()  { printf '%b\n' "${C_RED}x${C_RESET}  $*" >&2; }
die()  { err "$*"; exit 1; }

banner() {
    printf '%b\n' "${C_BOLD}${C_YELLOW}##################################################################${C_RESET}"
    local line
    for line in "$@"; do printf '%b\n' "${C_BOLD}${C_YELLOW}#${C_RESET}  $line"; done
    printf '%b\n' "${C_BOLD}${C_YELLOW}##################################################################${C_RESET}"
}

version() {
    cat <<EOF
$(basename "$0") $APP_VERSION (released $APP_RELEASE_DATE)
$APP_TITLE
Copyright (C) 2026 $APP_AUTHOR
License $APP_LICENSE: GNU AGPL version 3 or later <https://www.gnu.org/licenses/agpl-3.0.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
EOF
}

# ---- Configuration ----
# The file is parsed, never sourced: the script runs as root and the file
# may be writable by the operator, so it must never be able to run code.

# Prints why value $2 is wrong for key $1 and fails; silent if it is fine.
conf_check() {
    local key="$1" v="$2"
    if [[ "$v" == *[\"\\\`\$]* || "$v" == *$'\n'* || "$v" == *$'\r'* ]]; then
        echo "must not contain quotes, backslashes, \$, \` or line breaks"; return 1
    fi
    # Read back, a space followed by # starts a comment.
    if [[ "$v" =~ [[:space:]]# ]]; then
        echo "must not contain a space followed by #"; return 1
    fi
    case "$key" in
        BACKUP_DIR)   [[ -n "$v" ]] || { echo "must not be empty"; return 1; } ;;
        BACKUP_OWNER) [[ "$v" == user || "$v" == root ]] || { echo "must be user or root"; return 1; } ;;
        COMPRESS)     [[ "$v" == zstd || "$v" == zlib || "$v" == none ]] || { echo "must be zstd, zlib or none"; return 1; } ;;
        COMPARE)      [[ "$v" == yes || "$v" == no ]] || { echo "must be yes or no"; return 1; } ;;
        # Local connections only: other transports (ext, ssh) can make
        # libvirt run a command, and the disks are read locally anyway.
        LIBVIRT_URI)  [[ "$v" =~ ^qemu(\+unix)?:///(system|session)(\?socket=[A-Za-z0-9/_.-]+)?$ ]] || { echo "must be a local connection: qemu:///system or qemu:///session"; return 1; } ;;
        TEST_PREFIX)  [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]+-$ ]] || { echo "must be 3 or more of letters, digits, . _ -, start with a letter or digit and end with -"; return 1; } ;;
        TEST_BASE_DIR) : ;;
        TEST_NETWORK) [[ "$v" == yes || "$v" == no ]] || { echo "must be yes or no"; return 1; } ;;
        TEST_MODE)    [[ "$v" == overlay || "$v" == copy ]] || { echo "must be overlay or copy"; return 1; } ;;
        RESTORE_PREFIX) [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]+-$ ]] || { echo "must be 3 or more of letters, digits, . _ -, start with a letter or digit and end with -"; return 1; } ;;
        *) echo "is not a known setting (${CONF_KEYS[*]})"; return 1 ;;
    esac
}

conf_help() {
    case "$1" in
        BACKUP_DIR)    echo "folder for the backups; a relative path is relative to the config file's folder" ;;
        BACKUP_OWNER)  echo "user: the whole backup, disks included, belongs to who ran sudo (readable without sudo, see SECURITY); root: everything root's" ;;
        COMPRESS)      echo "zstd (QEMU 5.1+), zlib or none: compression inside the backup's qcow2, lossless" ;;
        COMPARE)       echo "yes: compare each backup disk with the original (qemu-img compare); no: skip, faster" ;;
        LIBVIRT_URI)   echo "libvirt connection; qemu:///system is the one virt-manager uses for system VMs" ;;
        TEST_PREFIX)   echo "name prefix of the test VM (prefix + VM name); test VMs are also marked, so a real VM is never mistaken for one" ;;
        TEST_BASE_DIR) echo "parent folder of the test VM's disks; empty: next to the original VM's disks" ;;
        TEST_NETWORK)  echo "default answer to 'test VM with network?': no (the original can run at the same time) or yes (only with the original shut off)" ;;
        TEST_MODE)     echo "overlay: test-boot the backup's own disks, read-only, changes in a small file; copy: test-boot a copy of them" ;;
        RESTORE_PREFIX) echo "prefix of the VM name and disk file names of a restore as a renamed copy" ;;
    esac
}

# Reads CONFIG_FILE (absent: defaults). One KEY=value per line, # for
# comments, value optionally in double or single quotes.
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local line key value why n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] \
            || die "$CONFIG_FILE line $n: expected KEY=value"
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%%[[:space:]]#*}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        why="$(conf_check "$key" "$value")" || die "$CONFIG_FILE line $n: $key $why"
        printf -v "$key" '%s' "$value"
    done < "$CONFIG_FILE"
    VIRSH=(virsh -c "$LIBVIRT_URI")
}

# Writes KEY="value" over the first line setting KEY (appended if none),
# keeping comments, owner and mode: the file is rewritten in place.
save_setting() {
    local key="$1" value="$2" content example="${SCRIPT_PATH%.sh}.conf.example"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        # First change: start from the shipped example, comments included.
        if [[ -f "$example" ]]; then
            cp -- "$example" "$CONFIG_FILE"
        else
            : > "$CONFIG_FILE"
        fi
        chown "$(operator_owner)" "$CONFIG_FILE"
        chmod 0644 "$CONFIG_FILE"
    fi
    content="$(awk -v k="$key" -v line="$key=\"$value\"" '
        !done && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print line; done = 1; next }
        { print }
        END { if (!done) print line }' "$CONFIG_FILE")"
    printf '%s\n' "$content" > "$CONFIG_FILE"
}

# A path from the configuration as an absolute one: relative paths start
# at the configuration file's folder, ~ is the home of who ran sudo.
conf_path() {
    local p="$1" home
    # shellcheck disable=SC2088  # the literal ~ written in the file
    if [[ "$p" == "~" || "$p" == "~/"* ]]; then
        home="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
        p="$home${p#\~}"
    fi
    [[ "$p" == /* ]] || p="$(dirname -- "$CONFIG_FILE")/${p#./}"
    printf '%s\n' "$p"
}

usage() {
    local me B R
    me="$(basename "$0")"
    B="$C_BOLD"; R="$C_RESET"
    cat <<EOF
${B}$me${R} - offline backup of a libvirt/KVM virtual machine, test boot
of the backup, and restore of the VM from it.

${B}USAGE${R}
  sudo $me [-c FILE]            interactive menu (lists VMs and backups)
  sudo $me [-c FILE] save DOMAIN [DEST_DIR]
  sudo $me [-c FILE] verify BACKUP_DIR
  sudo $me [-c FILE] test-start BACKUP_DIR [--overlay|--copy] [--with-network] [--test-dir DIR]
  sudo $me [-c FILE] test-clean DOMAIN
  sudo $me [-c FILE] restore BACKUP_DIR [DISK_DIR] [--copy]
  sudo $me [-c FILE] delete BACKUP_DIR
  $me -h | --help
  $me -V | --version

  -c, --config FILE   use FILE instead of the configuration file next
                      to the script (see CONFIGURATION)

  DOMAIN is the VM name as virt-manager or "virsh list --all" shows it.
  BACKUP_DIR is a folder made by save (DEST_DIR/DOMAIN-<timestamp>).
  Every command except --help needs root: disk images, NVRAM and TPM
  state are readable only by root or by the hypervisor's own user.

${B}COMMANDS${R}
  ${B}save DOMAIN [DEST_DIR]${R}
      Backs up a SHUT-OFF VM into a new folder DEST_DIR/DOMAIN-<timestamp>/.
      Without DEST_DIR: BACKUP_DIR of the configuration in use (see
      CONFIGURATION, and -c). A missing DEST_DIR is created (owner as
      BACKUP_OWNER says, existing parent folders unchanged); an existing
      one is used as it is. If a backup with the same name is already
      there, nothing is done. A running or paused VM is refused: shut it
      down from inside first. No snapshot is ever created.
      Smaller backups: inside the VM, run "sudo fstrim -av" just before
      shutting it down. It tells the disk which blocks deleted files
      left free, so they are not copied (Linux guests; on Windows,
      Optimize Drives does the same).
      The folder holds:
        domain.xml           the VM definition
        disk-<dev>.qcow2     one standalone qcow2 per disk (vda, sdb, ...)
        disk-<dev>.info.txt  qemu-img info of the original disk
        nvram.fd             UEFI variables (UEFI VMs only)
        tpm/                 emulated TPM state (only if the VM has one)
        sources.txt          where each file came from
        SHA256SUMS           checksums of all of the above
      Disks may be files, block devices (e.g. LVM) or storage-pool
      volumes, in any folder: their location is read from the VM
      definition. An external snapshot chain is flattened into one
      image; internal snapshots are not carried over; network disks
      (Ceph, iSCSI, ...) are refused. Free space is checked first.
      Each disk is compressed inside its qcow2 as COMPRESS says
      (lossless), and with COMPARE=yes compared with the original
      (qemu-img compare: the content the VM sees must be identical).
      Each disk is read in the format its definition declares, never a
      guessed one. If a conversion or a comparison fails, the VM is
      started during the backup, or the backup stops half way for any
      reason (an error, Ctrl-C), the folder is renamed <name>.INVALID and
      must be deleted.

  ${B}Free space${R} (save, test-start, restore)
      Shown for each disk written to before anything is written. Not
      enough room for the need plus 10% stops it, with what to change.
      Enough room but less than 10% of that disk left free afterwards
      asks first (needs a terminal): running VMs with disks there pause
      if it fills up.

  ${B}verify BACKUP_DIR${R}
      Re-checks every file of a backup against SHA256SUMS, and that the
      folder holds no file SHA256SUMS does not list. Run it after moving
      or archiving a backup, and before relying on it.

  ${B}test-start BACKUP_DIR [--overlay|--copy] [--with-network] [--test-dir DIR]${R}
      Test-boots a backup; the backup is only read, the original VM is
      not touched. Verifies the backup, defines and starts a temporary
      test VM named ${TEST_PREFIX}DOMAIN (TEST_PREFIX), marked as a test
      VM in its libvirt description. Its files go into a folder of that
      name in DIR (--test-dir), else TEST_BASE_DIR, else next to the
      original VM's disks if that folder exists here, else the "default"
      storage pool's folder, else /var/lib/libvirt/images.
      --overlay (default, TEST_MODE): the test VM boots the backup's own
      disks, opened read-only; what it writes goes into a small overlay
      file in the test folder. Needs about 1 GiB and starts at once, but
      the backup's disk must stay connected during the test, and the
      hypervisor's user (libvirt-qemu on Debian) must be able to pass
      through every folder above the backup folder: a disk mounted by the
      desktop under /media/<user>/ does not allow it (see README,
      external disk). The backup folder itself gets an ACL for that user,
      removed by test-clean.
      --copy: the test VM boots a copy of the backup's disks; needs the
      backup's size in the test folder and the time to copy it.
      Without --with-network the test VM has NO network card: a clone
      keeps the original's IP address, keys and scheduled jobs, and on
      the same network would clash with it or act as it. Check it from
      its console in virt-manager, while the original keeps running.
      --with-network keeps the network (new MAC address); refused while
      the original VM is running. The test VM never gets the original's
      passthrough host devices or host folder shares, and its console
      port is chosen automatically.

  ${B}test-clean DOMAIN${R}
      Stops and removes the temporary test VM ${TEST_PREFIX}DOMAIN
      started by test-start, its disk folder and TPM state. Refused for
      a VM without the test marker, whatever its name. Only a folder
      named exactly ${TEST_PREFIX}DOMAIN is ever deleted; the
      original VM is never touched. After an overlay test it gives the
      backup's disks back to the owner they had before, 0600 (libvirt
      lends them to its own user while the VM runs), removes the ACL
      test-start added, and
      re-verifies the backup. Safe to run after a failed test-start.

  ${B}restore BACKUP_DIR [DISK_DIR] [--copy]${R}
      Puts the VM back from its backup, with its original name, UUID
      and network card (same MAC, so the same DHCP lease or static IP).
      Each disk goes back to its original path: same folder, same file
      name. Refused while a VM with that name is defined, and if any
      target file exists: if the old VM is still there, broken, remove
      it first in virt-manager ("Delete") or with "virsh undefine
      DOMAIN" (add --nvram for a UEFI VM), and rename or remove its old
      disk files, or keep them and use --copy.
      --copy restores it as a renamed copy: VM ${RESTORE_PREFIX}DOMAIN
      (RESTORE_PREFIX), new UUID and MAC address, disks next to the
      originals as ${RESTORE_PREFIX}<original file name>, so it can live
      next to the original. Inside, the guest keeps the original's
      hostname, IP setup and keys: do not run both on the same network.
      DISK_DIR puts every disk there instead, under its original file
      name (prefixed with --copy): needed when an original folder does
      not exist on this host. The original folders must exist and hold
      no link. A disk that was a block device or a pool volume comes
      back as a file DISK_DIR/NAME-<dev>.qcow2 (without DISK_DIR: the
      first disk's folder, else the "default" pool's folder, else
      /var/lib/libvirt/images). NVRAM goes back to libvirt's NVRAM
      folder ($NVRAM_DIR) if it came from there (as NAME_VARS.fd for a
      copy), else next to the first disk; the TPM state to
      $SWTPM_DIR/<uuid>/. A VM that already uses the backup's UUID
      under another name also stops a restore that keeps the identity.
      Every target is shown and yes is asked before anything is written
      (so it needs a terminal); nothing existing is ever overwritten.
      The backup is verified first. Disks are written back uncompressed
      (full speed for the VM) and compared with the backup (qemu-img
      compare); NVRAM and TPM state are checked against SHA256SUMS. The
      VM is defined but NOT started.

  ${B}delete BACKUP_DIR${R}
      Deletes one backup folder, after showing its size, whether it is
      the only backup of that VM left in its folder, and asking to type
      yes (so it needs a terminal). Only a folder named like a backup
      (DOMAIN-<date>-<time>, or the same with .INVALID) and holding
      nothing but backup files is ever deleted; anything else stops it.
      The folder that contains it is checked to be still there after.

${B}CONFIGURATION${R}
  File: the script's own name with .conf, in the script's own folder,
  even when the script is run through a link (now: $CONFIG_FILE).
  -c FILE uses another one. Missing file or key: the default below.
  The project ships the same name with .conf.example: copy it to
  .conf, or let s in the menu create it from the example.
  One KEY=value per line, # for comments, value optionally in quotes.
  The file is read, never executed. s in the menu shows and changes
  the settings, keeping the comments.

  BACKUP_DIR     ./backup        folder the menu uses for backups; a
                                 relative path starts at the config
                                 file's folder, ~ is the sudo user's
                                 home. f in the menu changes it for one
                                 session only.
  BACKUP_OWNER   user            user: the whole backup, VM disks
                                 included, belongs to who ran sudo and
                                 is readable without sudo; root:
                                 everything is root's (see SECURITY
                                 before choosing)
  COMPRESS       zstd            compression inside each backup disk's
                                 qcow2: zstd (needs QEMU 5.1 or later),
                                 zlib or none. Lossless; the backup
                                 stays directly usable (verify, test
                                 boot) and restore writes it back
                                 uncompressed.
  COMPARE        yes             yes: after each disk is written,
                                 qemu-img compare checks that the VM
                                 sees the same content as the original
                                 (reads both in full, so slower);
                                 no: skip it
  LIBVIRT_URI    qemu:///system  libvirt connection, the one
                                 virt-manager uses for system VMs. Local
                                 only: qemu:///system or qemu:///session
                                 (other transports can run commands).
                                 Not a disk location.
  TEST_PREFIX    zztest-restore- name prefix of the test VM; letters,
                                 digits, . _ -, ending with -. Changing
                                 it hides test VMs made with the old
                                 one from test-clean: remove them first
  TEST_BASE_DIR  (empty)         parent folder of the test VM's files;
                                 empty: next to the original VM's disks,
                                 else the "default" pool's folder, else
                                 /var/lib/libvirt/images
  TEST_NETWORK   no              default answer in the menu to "test VM
                                 with network?": no lets the original
                                 run at the same time; yes needs it
                                 shut off
  TEST_MODE      overlay         default test-start mode: overlay (the
                                 backup's own disks, read-only) or copy
  RESTORE_PREFIX restore-        prefix of the VM name and disk file
                                 names of restore --copy

${B}EXAMPLE: THE WHOLE CYCLE${R}
  Folder names below use myvm and /mnt/backup: replace them with yours.

  0. Inside the VM, free the space of deleted files, then shut it down:
       sudo fstrim -av
       sudo poweroff        (or Shut Down in virt-manager)

  1. Back up the VM:
       sudo $me save myvm /mnt/backup
       (or "sudo $me save myvm": into BACKUP_DIR of the configuration)
       -> /mnt/backup/myvm-20261018-141829

  2. Verify the backup is intact:
       sudo $me verify /mnt/backup/myvm-20261018-141829

  3. Test-boot the backup, then remove the test VM:
       sudo $me test-start /mnt/backup/myvm-20261018-141829
       (virt-manager: open ${TEST_PREFIX}myvm, log in from the console,
        shut it down)
       sudo $me test-clean myvm

  ... later, the VM is lost or broken ...

  4. Verify the backup is still intact before using it:
       sudo $me verify /mnt/backup/myvm-20261018-141829

  5. Remove what is left of the broken VM, if anything:
       virt-manager: right click, Delete (or: sudo virsh undefine myvm),
       and rename or remove its old disk file
       (or keep it all and restore a copy: step 6 with --copy)

  6. Restore the VM from its backup, to its original disk paths:
       sudo $me restore /mnt/backup/myvm-20261018-141829
       (or into another folder, e.g. on a new host:
        sudo $me restore /mnt/backup/myvm-20261018-141829 /srv/vms
        or as ${RESTORE_PREFIX}myvm next to the original:
        sudo $me restore /mnt/backup/myvm-20261018-141829 --copy)

  7. Check the restored VM:
       sudo virsh start myvm        (or Start in virt-manager)
       log in, check its services and network as usual.
       sudo $me verify /mnt/backup/myvm-20261018-141829
       (the backup stays unchanged and usable for the next time)

${B}SECURITY${R}
  A backup holds the whole VM: every key, password and secret stored
  on it. Keep backups on encrypted storage only (LUKS): file owners
  and modes protect nothing once the disk is in other hands, since
  whoever holds it is root on their own machine.
  Ownership with BACKUP_OWNER=user, USER being the one who ran sudo:
    backup folder (and a DEST_DIR the menu creates)   USER, 0750
    domain.xml, sources.txt, *.info.txt, SHA256SUMS   USER, 0640
    disk-*.qcow2, nvram.fd                            USER, 0600
    tpm/                                              as the original
  With BACKUP_OWNER=root, or run as root without sudo, every line but
  tpm/ becomes root: folders 0700, files 0600.
  ${B}Danger of BACKUP_OWNER=user${R}: the VM disks are readable without
  sudo by anything that runs as USER: a malicious browser extension,
  a compromised program, a sync client (Nextcloud, Dropbox) that
  uploads the folder, a user backup tool that copies them to storage
  that is not encrypted. That is the point of it (user-level backup
  tools such as Back In Time can copy them), and the cost: choose root
  if nothing running as USER needs to read the backups.
  An existing DEST_DIR is never changed: if it is root's, browsing it
  still needs sudo. Console (VNC/SPICE) passwords are not saved in
  domain.xml: set them again after a restore. Restored disks and the
  test VM's are root 0600 like virt-manager's own; libvirt gives them
  to its own user while the VM runs (in an overlay test, the backup's
  disks too: test-clean gives them back to their owner, 0600).

${B}EXIT STATUS${R}
  0 on success; 1 on any error, with the reason on stderr.
EOF
}

domstate() {
    "${VIRSH[@]}" domstate "$1" 2>/dev/null | sed -n 1p
}

# domstate prints nothing both for "no such VM" and "libvirt down": every
# command that acts on that answer checks the connection first.
require_libvirt() {
    "${VIRSH[@]}" list --all --name >/dev/null 2>&1 \
        || die "cannot reach libvirt at $LIBVIRT_URI (is libvirtd running?): nothing done"
}

# True only for a test VM this script made: right prefix and marker.
is_test_vm() {
    [[ "$1" == "$TEST_PREFIX"* ]] || return 1
    [[ "$("${VIRSH[@]}" desc "$1" 2>/dev/null)" == "$TEST_MARKER" ]]
}

# Prints "kind<TAB>key<TAB>value" lines from a domain XML on stdin:
#   disk    <target dev>  file:<path> | block:<path> | volume:<pool>/<vol>
#   format  <target dev>  the disk's declared format (<driver type>), - if none
#   nvram   nvram         <path>
#   tpm     tpm           emulator      (state lives under SWTPM_DIR/<uuid>)
#   uuid    uuid          <uuid>
#   unsupported <target>  <disk type>
xml_sources() {
    python3 -I -c '
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
print("uuid\tuuid\t%s" % (root.findtext("uuid") or ""))
for d in root.findall("./devices/disk"):
    if d.get("device", "disk") in ("cdrom", "floppy"):
        continue
    tgt = d.find("target").get("dev")
    src = d.find("source")
    typ = d.get("type")
    drv = d.find("driver")
    print("format\t%s\t%s" % (tgt, (drv.get("type") if drv is not None else None) or "-"))
    if typ == "file" and src is not None and src.get("file"):
        print("disk\t%s\tfile:%s" % (tgt, src.get("file")))
    elif typ == "block" and src is not None and src.get("dev"):
        print("disk\t%s\tblock:%s" % (tgt, src.get("dev")))
    elif typ == "volume" and src is not None and src.get("pool") and src.get("volume"):
        print("disk\t%s\tvolume:%s/%s" % (tgt, src.get("pool"), src.get("volume")))
    else:
        print("unsupported\t%s\t%s" % (tgt, typ))
nv = root.find("./os/nvram")
if nv is not None and (nv.text or "").strip():
    print("nvram\tnvram\t%s" % nv.text.strip())
for t in root.findall("./devices/tpm/backend"):
    if t.get("type") == "emulator":
        print("tpm\ttpm\temulator")
'
}

# Writes a domain XML ($2) from a backup's domain.xml ($1) with every disk
# and the NVRAM pointed at new files. $3 mode: "test" (new name $4, test
# marker, no UUID so libvirt makes one, network removed or, with $5
# "true", kept with new MACs), "clone" (new name $4, new UUID and MACs,
# network kept: a restore under another name) or "restore" (name, UUID
# and MACs kept). $6..: remap entries "<value as in sources.txt>=<new path>".
rewrite_xml() {
    NDM_TEST_MARKER="$TEST_MARKER" python3 -I - "$@" <<'PY'
import os, sys, xml.etree.ElementTree as ET
src, dst, mode, name, with_net = sys.argv[1:6]
remap = dict(a.split("=", 1) for a in sys.argv[6:])
tree = ET.parse(src)
root = tree.getroot()
devices = root.find("devices")
if mode in ("test", "clone"):
    root.find("name").text = name
    if mode == "test":
        desc = root.find("description")
        if desc is None:
            desc = ET.SubElement(root, "description")
        desc.text = os.environ["NDM_TEST_MARKER"]
        # A throwaway VM must not take the original's passthrough devices
        # or write to its host shares, and must not fight it for a port.
        for tag in ("hostdev", "filesystem"):
            for el in devices.findall(tag):
                devices.remove(el)
        for g in devices.findall("graphics"):
            for a in ("port", "tlsPort", "websocket"):
                g.attrib.pop(a, None)
            if g.get("type") in ("vnc", "spice"):
                g.set("autoport", "yes")
    uuid = root.find("uuid")
    if uuid is not None:
        root.remove(uuid)
    for iface in devices.findall("interface"):
        if with_net == "true":
            mac = iface.find("mac")
            if mac is not None:
                iface.remove(mac)
        else:
            devices.remove(iface)
for d in devices.findall("disk"):
    s = d.find("source")
    if d.get("device") in ("cdrom", "floppy"):
        # The install medium may not exist here: drop it, keep the drive.
        if s is not None:
            d.remove(s)
        continue
    typ = d.get("type")
    if typ == "file":
        key = "file:" + s.get("file")
    elif typ == "block":
        key = "block:" + s.get("dev")
    else:
        key = "volume:%s/%s" % (s.get("pool"), s.get("volume"))
    # Every copied disk is a standalone qcow2 file now.
    d.set("type", "file")
    for a in list(s.attrib):
        del s.attrib[a]
    s.set("file", remap[key])
    drv = d.find("driver")
    if drv is None:
        # No declared format would make libvirt treat the qcow2 as raw.
        drv = ET.SubElement(d, "driver", {"name": "qemu"})
    drv.set("type", "qcow2")
    bs = d.find("backingStore")
    if bs is not None:
        d.remove(bs)
nv = root.find("./os/nvram")
if nv is not None and (nv.text or "").strip():
    nv.text = remap[nv.text.strip()]
tree.write(dst)
PY
}

# Format of pool volume $1 (<pool>/<volume>) as the pool records it.
volume_format() {
    local f
    f="$("${VIRSH[@]}" vol-dumpxml --pool "${1%%/*}" "${1#*/}" \
        | python3 -I -c 'import sys,xml.etree.ElementTree as ET; e=ET.parse(sys.stdin).getroot().find("./target/format"); print(e.get("type") if e is not None and e.get("type") else "raw")')" || return 1
    [[ "$f" =~ ^[a-z0-9]+$ ]] || return 1
    printf '%s\n' "$f"
}

# Resolves a disk value from xml_sources to a readable path.
disk_path() {
    local v="$1"
    case "$v" in
        file:*|block:*) printf '%s\n' "${v#*:}" ;;
        volume:*)
            local pv="${v#volume:}"
            "${VIRSH[@]}" vol-path --pool "${pv%%/*}" "${pv#*/}" ;;
    esac
}

# Default folder for disks made from the backup in $1: the original first
# disk's folder if it exists here, else the "default" pool's folder,
# else /var/lib/libvirt/images.
default_disk_dir() {
    local kind name orig dir
    while IFS=$'\t' read -r kind name orig; do
        [[ "$kind" == disk && "$orig" == file:* ]] || continue
        dir="$(dirname "${orig#file:}")"
        if [[ -d "$dir" ]]; then printf '%s\n' "$dir"; return; fi
        break
    done < "$1/sources.txt"
    dir="$("${VIRSH[@]}" pool-dumpxml default 2>/dev/null \
        | python3 -I -c 'import sys,xml.etree.ElementTree as ET; print(ET.parse(sys.stdin).getroot().findtext("./target/path") or "")' 2>/dev/null || true)"
    if [[ -n "$dir" && -d "$dir" ]]; then printf '%s\n' "$dir"; return; fi
    printf '%s\n' /var/lib/libvirt/images
}

backup_domain_name() {
    local domain
    domain="$(python3 -I -c 'import sys,xml.etree.ElementTree as ET; print(ET.parse(sys.argv[1]).getroot().findtext("name") or "")' "$1/domain.xml")"
    [[ "$domain" =~ ^[A-Za-z0-9._-]+$ ]] || die "unexpected domain name '$domain' in $1/domain.xml"
    printf '%s\n' "$domain"
}

backup_uuid() {
    python3 -I -c 'import sys,xml.etree.ElementTree as ET; print(ET.parse(sys.argv[1]).getroot().findtext("uuid") or "")' "$1/domain.xml"
}

human() { numfmt --to=iec-i --suffix=B --format=%.1f "$1"; }

# Free space, counted per filesystem: what goes into several folders on
# one disk adds up. space_add BYTES FOLDER for each write (a missing
# folder counts as its first existing parent), then space_check.
declare -A SPACE_NEED=() SPACE_AT=()
SPACE_LOW=()
space_add() {
    local need="$1" dir="$2" mnt
    while [[ ! -e "$dir" ]]; do dir="$(dirname -- "$dir")"; done
    mnt="$(df --output=target -- "$dir" | tail -1)"
    SPACE_NEED[$mnt]=$(( ${SPACE_NEED[$mnt]:-0} + need ))
    SPACE_AT[$mnt]="$dir"
}

# Shows need and free space on each filesystem, stops if one has no room
# for its need plus 10% ($1: how to make room, for the message). Fills
# SPACE_LOW when less than 10% of a filesystem would stay free: VMs with
# disks there pause when it fills up, so that is asked, not refused.
space_check() {
    local hint="$1" mnt need avail size
    SPACE_LOW=()
    for mnt in "${!SPACE_NEED[@]}"; do
        need="${SPACE_NEED[$mnt]}"
        read -r avail size < <(df --output=avail,size -B1 -- "${SPACE_AT[$mnt]}" | tail -1)
        info "space on $mnt: about $(human "$need") needed, $(human "$avail") free"
        (( avail > need + need / 10 )) \
            || die "not enough space on $mnt (${SPACE_AT[$mnt]}): about $(human "$need") needed, $(human "$avail") free. $hint"
        if (( avail - need < size / 10 )); then
            SPACE_LOW+=("${C_RED}Only $(human $((avail - need))) of $(human "$size") would stay free on $mnt:${C_RESET}"
                "running VMs with disks there pause if it fills up.")
        fi
    done
}

# Asks to go on despite SPACE_LOW, if set; without a terminal it stops.
space_low_confirm() {
    (( ${#SPACE_LOW[@]} > 0 )) || return 0
    [[ -t 0 ]] || die "less than 10% of the disk would stay free: run it from a terminal to confirm, or make room first"
    ask "${SPACE_LOW[@]}" "Type yes to go on anyway, anything else to stop:"
    [[ "$REPLY" == yes ]] || { info "nothing done"; exit 0; }
}

# The user QEMU runs as, which must reach an overlay's backing files.
qemu_user() {
    # Run as root, qemu:///session is root's own session: QEMU runs as root.
    if [[ "$LIBVIRT_URI" == *session* ]]; then echo root; return; fi
    local u
    u="$(sed -n 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' /etc/libvirt/qemu.conf 2>/dev/null | tail -1)"
    [[ "$u" == +* ]] && u="$(getent passwd "${u#+}" | cut -d: -f1)"
    if [[ -z "$u" ]]; then
        if id -u libvirt-qemu >/dev/null 2>&1; then u=libvirt-qemu; else u=qemu; fi
    fi
    printf '%s\n' "$u"
}

can_traverse() {
    setpriv --reuid="$1" --regid="$(id -g "$1")" --init-groups -- test -x "$2" 2>/dev/null
}

# Prints the first folder of path $2 that user $1 cannot pass through.
first_blocker() {
    local u="$1" p="" part
    local -a parts=()
    IFS=/ read -ra parts <<<"$2"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        p="$p/$part"
        if ! can_traverse "$u" "$p"; then
            echo "$p ($(stat -c '%U:%G %A' -- "$p")) does not let the hypervisor's user $u through"
            return 0
        fi
    done
    echo "the hypervisor's user $u cannot reach $2"
}

# Prints why an overlay test of backup $1 (a physical path) with its test
# folder in $2 cannot work, nothing if it can. test-start gives QEMU's
# user its way into the backup folder itself (an ACL); every folder above
# it, and the test folder's parent, must already let that user through.
overlay_blocker() {
    local dir="$1" base="$2" u
    # test-clean undoes the ACL only on a folder shaped like a backup.
    [[ "$(basename -- "$dir")" =~ $BACKUP_NAME_RE ]] \
        || { echo "the backup folder is not named as save names it (<vm>-<date>-<time>)"; return 0; }
    u="$(qemu_user)"
    id -u "$u" >/dev/null 2>&1 || { echo "the hypervisor's user '$u' does not exist here"; return 0; }
    if ! command -v setfacl >/dev/null || ! command -v getfacl >/dev/null; then
        echo "setfacl/getfacl not found (package acl)"; return 0
    fi
    [[ "$u" == root ]] && return 0
    can_traverse "$u" "$(dirname -- "$dir")" || { first_blocker "$u" "$(dirname -- "$dir")"; return 0; }
    can_traverse "$u" "$base" || { first_blocker "$u" "$base"; return 0; }
}

# Parent folder of the test VM's files for backup $1: TEST_BASE_DIR, or
# next to the original disks (see default_disk_dir).
test_base_dir() {
    if [[ -n "$TEST_BASE_DIR" ]]; then conf_path "$TEST_BASE_DIR"; else default_disk_dir "$1"; fi
}

# qemu-img convert options for COMPRESS. Compression inside qcow2 is
# per cluster and lossless; the image stays directly usable.
compress_opts() {
    case "$COMPRESS" in
        zstd) printf '%s\n' -c -o compression_type=zstd ;;
        zlib) printf '%s\n' -c ;;
    esac
}

# Renames a half-made backup to <name>.INVALID and stops with $2.
invalidate() {
    SAVE_IN_PROGRESS=""
    mv -- "$1" "$1.INVALID"
    die "$2: marked $1.INVALID, delete it"
}

# EXIT/INT/TERM trap of save: a backup stopped half way (an error, Ctrl-C)
# never stays behind looking complete.
SAVE_IN_PROGRESS=""
mark_interrupted() {
    if [[ -n "$SAVE_IN_PROGRESS" && -d "$SAVE_IN_PROGRESS" ]]; then
        mv -- "$SAVE_IN_PROGRESS" "$SAVE_IN_PROGRESS.INVALID"
        err "backup stopped before the end: marked $SAVE_IN_PROGRESS.INVALID, delete it"
        SAVE_IN_PROGRESS=""
    fi
}

# Checks file $2 against the SHA256SUMS entry for "./$3" in backup $1.
check_restored_file() {
    local backup="$1" file="$2" rel="$3" want got
    want="$(awk -v n="./$rel" '{ p = substr($0, 67) } p == n { print $1 }' "$backup/SHA256SUMS")"
    [[ -n "$want" ]] || die "$rel has no entry in $backup/SHA256SUMS"
    got="$(sha256sum -- "$file" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || die "$file does not match the backup's checksum for $rel"
}

# The file names in sources.txt become paths under the backup and under the
# target folder: only the two shapes save writes are accepted, so a name
# can never climb out of either. Each disk must be a plain qcow2 with no
# backing file: save never writes one, and a backing file would make
# qemu-img or the VM read another file. Checked before anything is copied.
check_backup_contents() {
    local kind name orig backing
    while IFS=$'\t' read -r kind name orig; do
        case "$kind" in
            disk)
                [[ "$name" =~ ^disk-[A-Za-z0-9._-]+\.qcow2$ ]] || die "$1/sources.txt: unexpected disk file name '$name'"
                backing="$(qemu-img info -f qcow2 --output=json "$1/$name" \
                    | python3 -I -c 'import sys,json; d=json.load(sys.stdin); print(d.get("backing-filename") or d.get("format-specific",{}).get("data",{}).get("data-file") or "")')" \
                    || die "$1/$name is not a readable qcow2 image"
                [[ -z "$backing" ]] || die "$1/$name refers to another file ($backing, backing or external data file): not a backup made by this script"
                ;;
            nvram) [[ "$name" == nvram.fd ]] || die "$1/sources.txt: unexpected NVRAM file name '$name'" ;;
        esac
    done < "$1/sources.txt"
}

# Owner of a backup (folders, descriptive files, disks, NVRAM): with
# BACKUP_OWNER=user the one who ran sudo, so user-level tools read it
# without sudo; with root, or no valid sudo user, root. TPM state keeps
# its owner.
operator_owner() {
    local u="${SUDO_USER:-root}" g
    [[ "$BACKUP_OWNER" == user ]] || u=root
    [[ "$u" =~ ^[a-z_][a-z0-9_.-]*\$?$ ]] && id -u "$u" >/dev/null 2>&1 || u=root
    g="$(id -gn "$u")"
    printf '%s:%s\n' "$u" "$g"
}

# Modes that go with operator_owner: shared with its group only when
# the operator is a user, root's own otherwise.
operator_dir_mode()  { [[ "$(operator_owner)" == root:* ]] && echo 0700 || echo 0750; }
operator_file_mode() { [[ "$(operator_owner)" == root:* ]] && echo 0600 || echo 0640; }

# Creates folder $1 (and missing parents) owned by the operator.
# Parents that already exist are left exactly as they are.
make_operator_dir() {
    local dir="$1" first="$1" owner mode
    while [[ ! -e "$(dirname "$first")" ]]; do first="$(dirname "$first")"; done
    mkdir -p -- "$dir"
    owner="$(operator_owner)"
    mode="$(operator_dir_mode)"
    # Only the folders created here: from the first missing one down.
    while true; do
        chown "$owner" "$dir"; chmod "$mode" "$dir"
        [[ "$dir" == "$first" ]] && break
        dir="$(dirname "$dir")"
    done
}

# Size a disk $1 of format $2 needs as an uncompressed qcow2. The format
# is always given: probed, a guest-written header on a raw disk could
# make qemu-img follow a "backing file" anywhere on the host.
measure_qcow2() {
    qemu-img measure -f "$2" -O qcow2 --output=json "$1" \
        | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["required"])'
}

# save DOMAIN [DEST_DIR] [ask]: without DEST_DIR, BACKUP_DIR of the
# configuration in use. A missing destination is created (after the VM
# checks, so a refused backup leaves nothing behind); an existing one is
# used as it is. "ask" (the menu) confirms once the space is shown.
cmd_save() {
    local domain="$1" dest="${2:-}" ask="${3:-}"
    # A name restore could not use again would make the backup useless.
    valid_vm_name "$domain" || die "VM name '$domain' cannot be backed up by this script (letters, digits, . _ -, starting with a letter or digit): rename it in virt-manager first"
    [[ -n "$dest" ]] || dest="$(conf_path "$BACKUP_DIR")"
    [[ ! -e "$dest" || -d "$dest" ]] || die "destination $dest exists but is not a folder"
    require_libvirt
    local state
    state="$(domstate "$domain")" || true
    [[ -n "$state" ]] || die "no domain named $domain on ${LIBVIRT_URI:-qemu:///system}"
    [[ "$state" == "shut off" ]] || die "$domain is '$state': shut it down first (only a shut-off VM can be backed up)"

    local xml
    # No --security-info: console (VNC/SPICE) passwords stay out of a file
    # the operator can read; set them again after a restore.
    xml="$("${VIRSH[@]}" dumpxml --inactive "$domain")"
    # Captured, not read through a process substitution: a failing parser
    # there would go unnoticed and leave a disk out of the backup.
    local sources
    sources="$(xml_sources <<<"$xml")" || die "$domain: cannot read the disks from its definition"

    local -a disk_paths=() disk_fmts=()
    local -A fmts=()
    local kind key value uuid="" nvram="" tpm=false path
    while IFS=$'\t' read -r kind key value; do
        case "$kind" in
            unsupported) die "$domain: disk $key is of type '$value', only local disks (file, block, pool volume) are supported" ;;
            uuid) uuid="$value" ;;
            format)
                # The device name ends up in the backup's file names.
                [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || die "$domain: unexpected disk device name '$key'"
                [[ "$value" == - || "$value" =~ ^[a-z0-9]+$ ]] || die "$domain: disk $key has an unexpected format '$value'"
                fmts[$key]="$value" ;;
            disk)
                path="$(disk_path "$value")" || die "$domain: cannot resolve disk $key ($value)"
                [[ -e "$path" ]] || die "$domain: disk $key: $path not found"
                # No <driver type>: for a pool volume the pool knows the
                # format; for a file or a device libvirt's default is raw.
                if [[ "${fmts[$key]:--}" == - ]]; then
                    if [[ "$value" == volume:* ]]; then
                        fmts[$key]="$(volume_format "${value#volume:}")" \
                            || die "$domain: cannot read the format of volume ${value#volume:}"
                    else
                        fmts[$key]=raw
                    fi
                fi
                disk_paths+=("$path"); disk_fmts+=("${fmts[$key]}") ;;
            nvram) nvram="$value"; [[ -f "$nvram" ]] || die "$domain: NVRAM $nvram not found" ;;
            tpm) tpm=true ;;
        esac
    done <<<"$sources"
    (( ${#disk_paths[@]} > 0 )) || die "$domain: no local disk found"
    local tpm_src="$SWTPM_DIR/$uuid"
    if $tpm && [[ ! -d "$tpm_src" ]]; then
        info "$domain has an emulated TPM but no state in $tpm_src yet: nothing to back up for it"
        tpm=false
    fi

    local i need=0
    for i in "${!disk_paths[@]}"; do
        need=$((need + $(measure_qcow2 "${disk_paths[$i]}" "${disk_fmts[$i]}")))
    done
    [[ -n "$nvram" ]] && need=$((need + $(stat -c %s "$nvram")))
    $tpm && need=$((need + $(du -sB1 "$tpm_src" | cut -f1)))
    # The uncompressed size: compression makes the backup smaller.
    space_add "$need" "$dest"
    space_check "Choose another folder: DEST_DIR, or BACKUP_DIR (s in the menu, f for this session only)."
    space_low_confirm
    if [[ "$ask" == ask ]]; then
        local owner_line="Disks owned by root (0600): reading them needs sudo."
        if [[ "$(operator_owner)" != root:* ]]; then
            owner_line="${C_YELLOW}Disks owned by ${SUDO_USER} (0600): readable WITHOUT sudo by anything running as ${SUDO_USER} (BACKUP_OWNER=user, see s and --help, SECURITY).${C_RESET}"
        fi
        confirm "Back up $domain into $dest?" \
            "(a new subfolder $domain-<timestamp> is created in it)" \
            "Keep $domain shut off until the backup ends." \
            "$owner_line"
    fi
    if [[ ! -d "$dest" ]]; then
        make_operator_dir "$dest"
        ok "created $dest (owned by $(operator_owner), $(operator_dir_mode))"
    fi

    local out name_now
    name_now="$domain-$(date +%Y%m%d-%H%M%S)"
    out="$dest/$name_now"
    if [[ -e "$out" || -e "$out.INVALID" ]]; then
        die "a backup named $name_now already exists in $dest: nothing done, wait a second and retry"
    fi
    # mkdir without -p fails if another run created the same folder in
    # the meantime: two backups never share one.
    mkdir "$out" 2>/dev/null || die "a backup named $name_now already exists in $dest: nothing done, wait a second and retry"
    # From here, any way out but success marks the folder .INVALID.
    SAVE_IN_PROGRESS="$out"
    trap mark_interrupted EXIT
    trap 'mark_interrupted; exit 130' INT TERM
    chown "$(operator_owner)" "$out"
    chmod "$(operator_dir_mode)" "$out"
    info "backing up $domain into $out (up to about $((need / 1024 / 1024)) MiB)"
    if [[ "$(operator_owner)" != root:* ]]; then
        info "BACKUP_OWNER=user: its disks will be readable without sudo by anything running as ${SUDO_USER} (see --help, SECURITY)"
    fi
    printf '%s\n' "$xml" > "$out/domain.xml"

    # sources.txt: kind, file in the backup, original path (disks: as the
    # XML names it, the key rewrite_xml uses to repoint the definition).
    : > "$out/sources.txt"
    local name fmt
    local -a copts=()
    mapfile -t copts < <(compress_opts)
    while IFS=$'\t' read -r kind key value; do
        [[ "$kind" == disk ]] || continue
        path="$(disk_path "$value")"
        name="disk-$key.qcow2"
        fmt="${fmts[$key]:-raw}"
        qemu-img info -f "$fmt" --backing-chain "$path" > "$out/disk-$key.info.txt"
        if ! qemu-img convert -p -f "$fmt" -O qcow2 "${copts[@]}" "$path" "$out/$name"; then
            invalidate "$out" "converting $path failed (COMPRESS=$COMPRESS; zstd needs QEMU 5.1 or later, else set COMPRESS=zlib or none)"
        fi
        ok "$path -> $name (compression: $COMPRESS)"
        # Proof, not trust: what the guest sees on both disks must match.
        if [[ "$COMPARE" == yes ]]; then
            info "comparing $name with $path (COMPARE=yes, reads both in full)"
            if ! qemu-img compare -p -f "$fmt" -F qcow2 "$path" "$out/$name"; then
                invalidate "$out" "$name differs from $path"
            fi
            ok "$name has the same content as $path"
        fi
        printf 'disk\t%s\t%s\n' "$name" "$value" >> "$out/sources.txt"
    done <<<"$sources"
    if [[ -n "$nvram" ]]; then
        cp --sparse=always -- "$nvram" "$out/nvram.fd"
        printf 'nvram\tnvram.fd\t%s\n' "$nvram" >> "$out/sources.txt"
        ok "$nvram -> nvram.fd"
    fi
    if $tpm; then
        cp -a -- "$tpm_src" "$out/tpm"
        printf 'tpm\ttpm\t%s\n' "$tpm_src" >> "$out/sources.txt"
        ok "$tpm_src -> tpm/"
    fi

    # Started during the backup: the files may be torn, the backup is useless.
    state="$(domstate "$domain")" || true
    if [[ "$state" != "shut off" ]]; then
        invalidate "$out" "$domain became '$state' during the backup"
    fi

    local sums
    sums="$(cd "$out" && find . -type f -print0 | sort -z | xargs -0 sha256sum --)"
    printf '%s\n' "$sums" > "$out/SHA256SUMS"
    ok "checksums written"
    # Descriptive files readable by the operator. Disks and NVRAM get the
    # same owner but stay 0600: with BACKUP_OWNER=user that owner reads
    # the whole VM without sudo (see SECURITY). tpm/ keeps the owner of
    # the original state, which swtpm needs.
    local f
    for f in "$out"/domain.xml "$out"/sources.txt "$out"/disk-*.info.txt "$out"/SHA256SUMS; do
        chown "$(operator_owner)" "$f"
        chmod "$(operator_file_mode)" "$f"
    done
    for f in "$out"/disk-*.qcow2 "$out"/nvram.fd; do
        [[ -f "$f" ]] || continue
        chown "$(operator_owner)" "$f"
        chmod 0600 "$f"
    done
    SAVE_IN_PROGRESS=""
    trap - EXIT INT TERM
    banner "Backup of $domain in $out" \
        "It holds the whole VM, every key and secret stored on it." \
        "Keep it on encrypted storage only." \
        "Next: verify it, then test-boot it with test-start (see --help)."
}

cmd_verify() {
    local dir="$1" listed present
    [[ -f "$dir/SHA256SUMS" ]] || die "$dir/SHA256SUMS not found"
    (cd "$dir" && sha256sum --quiet -c SHA256SUMS) || die "checksum mismatch in $dir"
    # And nothing else: a file save never wrote means the folder changed.
    listed="$(cut -c67- "$dir/SHA256SUMS" | sort)"
    present="$(cd "$dir" && find . -type f ! -path ./SHA256SUMS | sort)"
    [[ "$listed" == "$present" ]] || die "$dir holds files that SHA256SUMS does not list: changed after the backup"
    ok "$dir: every file matches SHA256SUMS"
}

# test-start BACKUP_DIR WITH_NETWORK [MODE] [BASE]: MODE overlay or copy
# (default TEST_MODE), BASE the test folder's parent (default
# test_base_dir). An overlay is a qcow2 whose unchanged blocks are read
# from the backup's disk, opened read-only; everything the test VM
# writes goes into the overlay. A copy duplicates the backup's disks.
cmd_test_start() {
    local dir="$1" with_network="$2" mode="${3:-$TEST_MODE}" base="${4:-}"
    cmd_verify "$dir"
    # Physical: the overlays and the ACL must name the real folder.
    dir="$(cd "$dir" && pwd -P)"
    require_libvirt
    check_backup_contents "$dir"
    local domain
    domain="$(backup_domain_name "$dir")"
    local test_name="$TEST_PREFIX$domain"
    [[ -z "$(domstate "$test_name")" ]] || die "$test_name already exists: test-clean $domain first"
    if $with_network; then
        local state
        state="$(domstate "$domain")" || true
        [[ -z "$state" || "$state" == "shut off" ]] || die "$domain is '$state': --with-network needs it shut off (same IP and identity)"
    fi

    [[ -n "$base" ]] || base="$(test_base_dir "$dir")"
    [[ -d "$base" ]] || die "test folder $base does not exist"
    base="$(cd "$base" && pwd -P)"
    local tdir="$base/$test_name"
    [[ ! -e "$tdir" ]] || die "$tdir already exists: test-clean $domain first"
    local quser="" acl_before="" why
    if [[ "$mode" == overlay ]]; then
        why="$(overlay_blocker "$dir" "$base")"
        [[ -z "$why" ]] || die "overlay test not possible: $why. Use the copy mode (--copy), or see the README (test boot, external disk)"
        quser="$(qemu_user)"
        space_add "$OVERLAY_ROOM" "$base"
    else
        space_add "$(du -sB1 "$dir" | cut -f1)" "$base"
    fi
    space_check "Choose another test folder: --test-dir, TEST_BASE_DIR, or the folder question in the menu."
    space_low_confirm

    # Traversable by the hypervisor's own user (libvirt-qemu on Debian):
    # libvirt chowns the disk files at start, never their directory.
    mkdir -m 0711 "$tdir"
    # Until the test VM is defined, test-clean could not find this folder:
    # any way out undoes it here.
    TEST_SETUP="$tdir"
    trap test_setup_undo EXIT
    trap 'test_setup_undo; exit 130' INT TERM HUP
    if [[ "$mode" == overlay ]]; then
        # Recorded before the ACL and before libvirt lends the disks to
        # its user: test-clean puts back exactly this. Numeric, so a
        # user without a name still round-trips through chown.
        if [[ -n "$(getfacl -c --skip-base -- "$dir" 2>/dev/null)" ]]; then acl_before=extended; else acl_before=none; fi
        local disk_owner first_disk
        first_disk="$(compgen -G "$dir/disk-*.qcow2" | head -1)"
        disk_owner="$(stat -c '%u:%g' -- "$first_disk")"
        # A test whose clean-up never ran leaves the disks with QEMU's
        # user: recording that would make it permanent.
        if [[ "$quser" != root && "${disk_owner%%:*}" == "$(id -u "$quser")" ]]; then
            die "$dir's disks still belong to $quser (a test that was never cleaned up?): give them back to the backup's owner first: chown $(stat -c '%u:%g' -- "$dir") $dir/disk-*.qcow2"
        fi
        printf 'mode\toverlay\nbackup\t%s\nuser\t%s\nacl\t%s\ndiskowner\t%s\n' "$dir" "$quser" "$acl_before" "$disk_owner" > "$tdir/$TEST_INFO"
        if [[ "$quser" != root ]]; then
            setfacl -m "u:$quser:x" -- "$dir" \
                || die "cannot give $quser access to $dir (does its filesystem support ACLs?): use the copy mode (--copy)"
            ok "$quser may now pass through $dir (removed by test-clean)"
        fi
    else
        printf 'mode\tcopy\nbackup\t%s\n' "$dir" > "$tdir/$TEST_INFO"
    fi
    local kind name orig has_tpm=false
    local -a map=()
    while IFS=$'\t' read -r kind name orig; do
        case "$kind" in
            disk)
                if [[ "$mode" == overlay ]]; then
                    qemu-img create -q -f qcow2 -b "$dir/$name" -F qcow2 "$tdir/$name" \
                        || die "creating the overlay of $name failed"
                else
                    cp --sparse=always -- "$dir/$name" "$tdir/$name"
                fi
                map+=("$orig=$tdir/$name") ;;
            nvram)
                # The VM writes its UEFI variables: always its own copy.
                cp --sparse=always -- "$dir/$name" "$tdir/$name"
                map+=("$orig=$tdir/$name") ;;
            tpm) has_tpm=true ;;
        esac
    done < "$dir/sources.txt"
    if [[ "$mode" == overlay ]]; then
        ok "overlays made in $tdir: the backup's disks are only read"
    else
        ok "disks duplicated for the test VM in $tdir"
    fi

    rewrite_xml "$dir/domain.xml" "$tdir/domain.xml" test "$test_name" "$with_network" "${map[@]}"
    "${VIRSH[@]}" define "$tdir/domain.xml" >/dev/null
    # Defined: from here test-clean finds the folder through the VM.
    TEST_SETUP=""
    trap - EXIT INT TERM HUP
    if $has_tpm; then
        local new_uuid
        new_uuid="$("${VIRSH[@]}" domuuid "$test_name")"
        [[ ! -e "$SWTPM_DIR/$new_uuid" ]] || die "$SWTPM_DIR/$new_uuid already exists"
        cp -a -- "$dir/tpm" "$SWTPM_DIR/$new_uuid"
        ok "TPM state copied for $test_name"
    fi
    "${VIRSH[@]}" start "$test_name" >/dev/null
    ok "$test_name defined and started"
    local -a lines=()
    if $with_network; then
        lines+=("$test_name runs WITH network, as $domain: same IP, keys, jobs."
            "Keep $domain shut off until: test-clean $domain")
    else
        lines+=("$test_name runs WITHOUT network: check it from its console."
            "When done: test-clean $domain")
    fi
    if [[ "$mode" == overlay ]]; then
        lines+=("The backup's disks are only read; what the test VM writes goes"
            "into $tdir. Keep the backup's disk connected until test-clean.")
    else
        lines+=("The test VM works on its copy in $tdir.")
    fi
    lines+=("Its files there grow with what it writes: keep the test short.")
    banner "${lines[@]}"
}

cmd_test_clean() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9._-]+$ ]] || die "unexpected domain name '$domain'"
    local test_name="$TEST_PREFIX$domain" tdir=""
    local state uuid="" d kind key value extra
    require_libvirt
    state="$(domstate "$test_name")" || true
    if [[ -n "$state" ]]; then
        is_test_vm "$test_name" || die "$test_name exists but is not a test VM made by this script (no test marker): not touched"
        uuid="$("${VIRSH[@]}" domuuid "$test_name")"
        # The test directory is where the test domain's disks are; only
        # a directory named after the test domain is ever removed.
        while IFS=$'\t' read -r kind key value; do
            [[ "$kind" == disk && "$value" == file:* ]] || continue
            d="$(dirname "${value#file:}")"
            [[ "$(basename "$d")" == "$test_name" ]] && tdir="$d"
            break
        done < <("${VIRSH[@]}" dumpxml --inactive "$test_name" | xml_sources)
        [[ "$state" == "shut off" ]] || "${VIRSH[@]}" destroy "$test_name" >/dev/null
        "${VIRSH[@]}" undefine --nvram "$test_name" >/dev/null 2>&1 || "${VIRSH[@]}" undefine "$test_name" >/dev/null
        ok "$test_name undefined"
    fi
    # Only the test domain's own TPM state, found by its own uuid.
    if [[ "$uuid" =~ ^[0-9a-f-]{36}$ && -d "$SWTPM_DIR/$uuid" ]]; then
        rm -rf -- "${SWTPM_DIR:?}/$uuid"
        ok "$SWTPM_DIR/$uuid removed"
    fi
    if [[ -z "$tdir" && -n "$TEST_BASE_DIR" ]]; then
        tdir="$(conf_path "$TEST_BASE_DIR")/$test_name"
    fi
    if [[ -n "$tdir" && -d "$tdir" ]]; then
        # Only what test-start puts there; anything else stops it.
        extra="$(find "$tdir" -mindepth 1 -maxdepth 1 ! -name domain.xml ! -name 'disk-*.qcow2' \
            ! -name nvram.fd ! -name "$TEST_INFO" -printf '%f ')"
        [[ -z "$extra" ]] || die "$tdir also holds files test-start never writes (${extra:0:200}): not removed, check it by hand"
        undo_backup_access "$tdir"
        rm -rf --one-file-system -- "$tdir"
        ok "$tdir removed"
    elif [[ -z "$tdir" ]]; then
        info "test directory not found from the domain definition: if one is left, rerun with TEST_BASE_DIR=<its parent>"
    fi
    [[ -z "$(domstate "$test_name")" && ( -z "$tdir" || ! -e "$tdir" ) ]] || die "leftovers: check $test_name and $tdir"
    # An overlay test read the backup in place: prove it is unchanged.
    if [[ -n "$UNDONE_BACKUP" ]]; then
        info "re-checking the backup the test VM read: $UNDONE_BACKUP"
        cmd_verify "$UNDONE_BACKUP"
    fi
    state="$(domstate "$domain")" || true
    info "original $domain: ${state:-not defined on this host}"
}

# Reads test folder $1's TEST_INFO: after an overlay test, gives the
# backup's disks back to the owner they had before the test, 0600
# (libvirt hands them to its own user while the VM runs, and a crash
# can leave them so) and removes the ACL test-start added. Sets
# UNDONE_BACKUP to the backup it fixed, if any.
UNDONE_BACKUP=""
undo_backup_access() {
    local info="$1/$TEST_INFO" key value mode="" backup="" quser="" acl="" f
    # Tests started by 1.1.0 have no diskowner line: disks were root's then.
    local downer="0:0"
    UNDONE_BACKUP=""
    [[ -f "$info" ]] || return 0
    while IFS=$'\t' read -r key value; do
        case "$key" in
            mode) mode="$value" ;; backup) backup="$value" ;;
            user) quser="$value" ;; acl) acl="$value" ;;
            diskowner) downer="$value" ;;
        esac
    done < "$info"
    [[ "$mode" == overlay ]] || return 0
    # Never fatal: the caller removes the test folder in any case, and a
    # failure here must not leave it behind, unreachable by test-clean.
    local manual="chown $downer and chmod 0600 $backup/disk-*.qcow2, then setfacl -b $backup (or setfacl -x u:$quser $backup if it had other ACL entries)"
    [[ "$quser" =~ ^[a-z_][a-z0-9_.-]*$ ]] || { err "unexpected user '$quser' in $info: check $backup by hand: $manual"; return 0; }
    [[ "$downer" =~ ^[0-9]+:[0-9]+$ ]] || { err "unexpected disk owner '$downer' in $info: check $backup by hand: $manual"; return 0; }
    # Only a folder shaped like a backup, as test-start checked it.
    if [[ "$backup" != /* || ! "$(basename -- "$backup")" =~ $BACKUP_NAME_RE || ! -f "$backup/SHA256SUMS" || -L "$backup" ]]; then
        err "the backup this test read ($backup) is not reachable now (disk disconnected?)."
        err "When it is back: $manual"
        return 0
    fi
    local failed=false
    for f in "$backup"/disk-*.qcow2; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        { chown "$downer" -- "$f" && chmod 0600 -- "$f"; } || failed=true
    done
    if [[ "$quser" != root ]]; then
        if [[ "$acl" == none ]]; then
            setfacl -b -- "$backup" || failed=true
        else
            setfacl -x "u:$quser" -- "$backup" || failed=true
        fi
    fi
    if $failed; then
        err "could not fully put back the permissions of $backup: $manual"
        return 0
    fi
    ok "backup $backup: disks back to $downer 0600, test access removed"
    UNDONE_BACKUP="$backup"
}

# EXIT/INT/TERM trap of test-start before the test VM exists: removes the
# half-made test folder and what it changed on the backup.
TEST_SETUP=""
test_setup_undo() {
    [[ -n "$TEST_SETUP" && -d "$TEST_SETUP" ]] || return 0
    # A trap keeps set -e: a failing step would skip the rest.
    set +e
    undo_backup_access "$TEST_SETUP"
    if rm -rf --one-file-system -- "$TEST_SETUP"; then
        err "test-start stopped before the end: $TEST_SETUP removed"
    else
        err "test-start stopped before the end: remove $TEST_SETUP by hand"
    fi
    TEST_SETUP=""
}

# A VM name usable in libvirt and in disk file names.
valid_vm_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# Original folders of backup $1's file disks that restore without
# DISK_DIR cannot use, one per line: missing here, not absolute, or with
# a link in them (the same tests cmd_restore applies).
restore_missing_dirs() {
    local kind name orig d
    while IFS=$'\t' read -r kind name orig; do
        [[ "$kind" == disk && "$orig" == file:* ]] || continue
        d="$(dirname -- "${orig#file:}")"
        if [[ "$d" != /* || ! -d "$d" || "$(readlink -f -- "$d")" != "$d" ]]; then
            printf '%s\n' "$d"
        fi
    done < "$1/sources.txt" | sort -u
}

# restore BACKUP_DIR [DISK_DIR] [COPY]: COPY "false" keeps the VM's
# identity (name, UUID, MACs); "true" makes a renamed copy (prefix
# RESTORE_PREFIX, new UUID and MACs) that can live next to the
# original. Each file disk goes back to its original path (its folder,
# its file name, with the prefix for a copy), or into DISK_DIR under its
# original file name. Shows every target and asks before writing.
cmd_restore() {
    local dir="$1" disk_dir="${2:-}" copy="${3:-false}"
    [[ -t 0 ]] || die "restore asks for confirmation: run it from a terminal"
    cmd_verify "$dir"
    # Absolute: the TPM check below reads SHA256SUMS from another folder.
    dir="$(cd "$dir" && pwd)"
    require_libvirt
    check_backup_contents "$dir"
    local domain uuid vm_name renamed=false prefix=""
    domain="$(backup_domain_name "$dir")"
    uuid="$(backup_uuid "$dir")"
    vm_name="$domain"
    if [[ "$copy" == true ]]; then
        renamed=true; prefix="$RESTORE_PREFIX"; vm_name="$RESTORE_PREFIX$domain"
    fi
    valid_vm_name "$vm_name" || die "'$vm_name' is not a usable VM name (letters, digits, . _ -; not starting with . _ -)"
    if [[ -n "$(domstate "$vm_name")" ]]; then
        if $renamed; then
            die "a VM named $vm_name is defined: remove it first, or change RESTORE_PREFIX"
        fi
        die "a VM named $vm_name is defined: remove it first (see --help, restore), restore it as a renamed copy (--copy), or use test-start to test-boot the backup"
    fi
    local holder=""
    if ! $renamed && [[ -n "$uuid" ]]; then
        holder="$("${VIRSH[@]}" domname "$uuid" 2>/dev/null | sed -n 1p)" || holder=""
    fi
    [[ -z "$holder" ]] || die "a VM with this backup's UUID is defined ($holder): restore it as a renamed copy (--copy), or remove that VM first"
    if [[ -n "$disk_dir" ]]; then
        [[ -d "$disk_dir" ]] || die "disk folder $disk_dir does not exist"
        disk_dir="$(cd "$disk_dir" && pwd)"
    fi

    # Every target decided and checked before anything is written. The
    # original paths come from the backup, which the operator may own and
    # this runs as root: each one is shown before the yes, must be
    # absolute, link-free, in an existing folder, and is never overwritten.
    local kind name orig target p tfolder base other=""
    local -a names=() targets=() map=() notes=()
    local tpm_target="" has_tpm=false
    while IFS=$'\t' read -r kind name orig; do
        case "$kind" in
            disk)
                if [[ "$orig" == file:* ]]; then
                    p="${orig#file:}"
                    base="$(basename -- "$p")"
                    # No backslash either: the confirmation prints with %b,
                    # and an escape there could hide a line of it.
                    [[ "$base" =~ ^[^[:cntrl:]/\\]+$ && "$base" != . && "$base" != .. ]] \
                        || die "$name: unusable original file name in $p (control characters or a backslash): not a backup made from a usual disk file name"
                    if [[ -n "$disk_dir" ]]; then
                        tfolder="$disk_dir"
                    else
                        tfolder="$(dirname -- "$p")"
                        [[ "$tfolder" == /* ]] || die "$name: original path $p is not absolute"
                        [[ -d "$tfolder" ]] || die "$name: the original folder $tfolder does not exist here: give a folder for the disks (restore BACKUP_DIR DISK_DIR; the menu asks for it)"
                        [[ "$(readlink -f -- "$tfolder")" == "$tfolder" ]] \
                            || die "$name: $tfolder holds a link or . / .. : give a folder for the disks (restore BACKUP_DIR DISK_DIR)"
                    fi
                    target="$tfolder/$prefix$base"
                else
                    # A block device or a pool volume is not recreated: it
                    # comes back as a file.
                    [[ -n "$other" ]] || other="${disk_dir:-$(default_disk_dir "$dir")}"
                    target="$other/$vm_name-${name#disk-}"
                    notes+=("$name was ${orig%%:*} ${orig#*:}: it comes back as a file.")
                fi ;;
            nvram)
                # Only libvirt's own NVRAM folder is trusted as a target,
                # anything else goes next to the first disk.
                if $renamed; then
                    target="$NVRAM_DIR/${vm_name}_VARS.fd"
                else
                    target="$NVRAM_DIR/$(basename -- "$orig")"
                fi
                [[ "$(dirname -- "$orig")" == "$NVRAM_DIR" && -d "$NVRAM_DIR" && "$(basename -- "$target")" =~ ^[A-Za-z0-9._-]+$ ]] \
                    || { [[ -n "${targets[0]:-}" ]] || die "$dir/sources.txt: NVRAM listed before the disks"
                         target="$(dirname -- "${targets[0]}")/${vm_name}_VARS.fd"; } ;;
            tpm)
                has_tpm=true
                # Under another name the UUID is new, known only after
                # define: the state is copied there afterwards.
                if ! $renamed; then
                    [[ "$uuid" =~ ^[0-9a-f-]{36}$ ]] || die "backup has TPM state but no valid UUID in domain.xml"
                    tpm_target="$SWTPM_DIR/$uuid"
                    [[ ! -e "$tpm_target" ]] || die "$tpm_target already exists: TPM state of a VM with this UUID is still there"
                fi
                continue ;;
            *) continue ;;
        esac
        if [[ -e "$target" || -L "$target" ]]; then
            if $renamed; then
                die "$target already exists: nothing is overwritten. Move it away, or restore into another folder (restore BACKUP_DIR DISK_DIR --copy)"
            fi
            die "$target already exists: nothing is overwritten. Rename or remove the old file first, restore it as a renamed copy (--copy), or into another folder (restore BACKUP_DIR DISK_DIR)"
        fi
        for p in "${targets[@]}"; do
            [[ "$p" != "$target" ]] || die "two files of the backup would both become $target (same file name): without DISK_DIR each disk goes back to its own folder"
        done
        names+=("$name"); targets+=("$target"); map+=("$orig=$target")
    done < "$dir/sources.txt"
    # Disks come back uncompressed: room for their full size, not the
    # backup's.
    local i
    for i in "${!names[@]}"; do
        if [[ "${names[$i]}" == disk-* ]]; then
            space_add "$(measure_qcow2 "$dir/${names[$i]}" qcow2)" "$(dirname -- "${targets[$i]}")"
        else
            space_add "$(stat -c %s "$dir/${names[$i]}")" "$(dirname -- "${targets[$i]}")"
        fi
    done
    space_check "Restore into another folder: restore BACKUP_DIR DISK_DIR."

    local -a lines=("Restore $domain from $(basename "$dir") as $vm_name:")
    if $renamed; then
        lines+=("a new VM (new UUID and MAC address) next to the original.")
    else
        lines+=("same name, UUID and network card as when backed up.")
    fi
    for i in "${!names[@]}"; do lines+=("  ${names[$i]} -> ${targets[$i]}"); done
    $has_tpm && lines+=("  tpm/ -> $SWTPM_DIR/<uuid>/")
    lines+=("${notes[@]}" "${SPACE_LOW[@]}"
        "Nothing existing is overwritten. The VM is NOT started."
        "Type yes to go ahead, anything else to stop:")
    ask "${lines[@]}"
    [[ "$REPLY" == yes ]] || { info "nothing done"; exit 0; }

    for i in "${!names[@]}"; do
        if [[ "${names[$i]}" == disk-* ]]; then
            # Rewritten uncompressed so the VM runs at full speed; a new
            # file cannot match the backup's checksum, so its content is
            # compared with the backup instead.
            qemu-img convert -p -f qcow2 -O qcow2 "$dir/${names[$i]}" "${targets[$i]}" \
                || die "restoring ${names[$i]} failed: remove ${targets[$i]} if it was created"
            qemu-img compare -p -f qcow2 -F qcow2 "$dir/${names[$i]}" "${targets[$i]}" \
                || die "${targets[$i]} differs from the backup's ${names[$i]}: remove it and retry"
            ok "${names[$i]} -> ${targets[$i]} (uncompressed, same content as the backup)"
        else
            cp --sparse=always -- "$dir/${names[$i]}" "${targets[$i]}"
            check_restored_file "$dir" "${targets[$i]}" "${names[$i]}"
            ok "${names[$i]} -> ${targets[$i]} (checksum matches)"
        fi
    done
    if [[ -n "$tpm_target" ]]; then
        restore_tpm "$dir" "$tpm_target"
    fi

    local xml_out
    xml_out="$(mktemp)"
    if $renamed; then
        rewrite_xml "$dir/domain.xml" "$xml_out" clone "$vm_name" true "${map[@]}"
    else
        rewrite_xml "$dir/domain.xml" "$xml_out" restore "$vm_name" true "${map[@]}"
    fi
    if ! "${VIRSH[@]}" define "$xml_out" >/dev/null; then
        rm -f -- "$xml_out"
        die "libvirt refused the definition of $vm_name: the restored files above stay, remove them before retrying"
    fi
    rm -f -- "$xml_out"
    [[ "$(domstate "$vm_name")" == "shut off" ]] || die "$vm_name was not defined as expected: check virsh list --all"
    if $renamed && $has_tpm; then
        tpm_target="$SWTPM_DIR/$("${VIRSH[@]}" domuuid "$vm_name")"
        [[ ! -e "$tpm_target" ]] || die "$tpm_target already exists"
        restore_tpm "$dir" "$tpm_target"
    fi
    if $renamed; then
        ok "$vm_name defined from the backup of $domain, shut off, with a new UUID and MAC address"
        banner "$domain restored as $vm_name, NOT started." \
            "Inside, the guest still has $domain's hostname, IP setup and keys:" \
            "change them before running it next to $domain on the same network." \
            "Then re-verify the backup: verify $dir"
    else
        ok "$vm_name defined, shut off, same UUID and network card as when backed up"
        banner "$vm_name restored, NOT started." \
            "Start it (virt-manager, or: virsh start $vm_name), log in, check it." \
            "Then re-verify the backup: verify $dir"
    fi
}

# Copies backup $1's TPM state to $2 and checks it against SHA256SUMS.
restore_tpm() {
    local dir="$1" target="$2"
    cp -a -- "$dir/tpm" "$target"
    (cd "$target" && grep '  \./tpm/' "$dir/SHA256SUMS" | sed 's#  \./tpm/#  ./#' | sha256sum --quiet -c -) \
        || die "TPM state in $target does not match the backup's checksums"
    ok "tpm/ -> $target (checksums match)"
}

cmd_delete() {
    local dir="${1%/}"
    [[ -d "$dir" && ! -L "$dir" ]] || die "$dir is not a folder"
    dir="$(cd "$dir" && pwd)"
    local base parent vm
    base="$(basename "$dir")"
    parent="$(dirname "$dir")"
    [[ "$base" =~ $BACKUP_NAME_RE ]] || die "$base is not named like a backup (<vm>-<date>-<time>): not deleted"
    if [[ "$base" != *.INVALID ]]; then
        [[ -f "$dir/domain.xml" && -f "$dir/sources.txt" ]] || die "$dir has no domain.xml/sources.txt, so it is not a backup: not deleted"
    fi
    # Anything a backup never holds means it is not (only) a backup.
    local extra
    extra="$(find "$dir" -mindepth 1 -maxdepth 1 ! -name domain.xml ! -name sources.txt \
        ! -name SHA256SUMS ! -name 'disk-*.qcow2' ! -name 'disk-*.info.txt' ! -name nvram.fd \
        ! -name tpm -printf '%f ')"
    [[ -z "$extra" ]] || die "$dir also holds files a backup never has (${extra:0:200}): not deleted, check it by hand"

    vm="${base%.INVALID}"; vm="${vm%-*-*}"
    local others=0 d dbase
    for d in "$parent/$vm"-*; do
        [[ "$d" == "$dir" || "$d" == *.INVALID || ! -f "$d/SHA256SUMS" ]] && continue
        dbase="$(basename "$d")"
        # Same VM only: "web" must not count web-01's backups.
        [[ "$dbase" =~ $BACKUP_NAME_RE && "${dbase%-*-*}" == "$vm" ]] && others=$((others + 1))
    done

    local -a lines=("Delete $dir ($(du -sh "$dir" | cut -f1))?")
    if [[ "$base" == *.INVALID ]]; then
        lines+=("It is an interrupted backup, not usable anyway.")
    elif (( others == 0 )); then
        lines+=("${C_RED}It is the ONLY backup of $vm in $parent.${C_RESET}")
    else
        lines+=("$others other backup(s) of $vm stay in $parent.")
    fi
    lines+=("This cannot be undone." "Type yes to delete, anything else to stop:")
    ask "${lines[@]}"
    [[ "$REPLY" == yes ]] || { info "nothing deleted"; exit 0; }

    rm -rf --one-file-system -- "$dir"
    [[ ! -e "$dir" ]] || die "$dir is still there: check it by hand"
    [[ -d "$parent" ]] || die "$parent is gone: this must never happen, check it now"
    ok "$dir deleted ($parent untouched)"
}

# ---- Interactive mode (no arguments) ----
# Every choice ends in one of the cmd_* functions above, with the same
# checks as the command line: the menus only help pick the arguments.

# Framed question (a one-line prompt gets lost in the output above it),
# answer read from the terminal into REPLY.
ask() {
    local line
    printf '\n%b\n' "${C_BOLD}+------------------------------------------------------------------${C_RESET}"
    for line in "$@"; do printf '%b\n' "${C_BOLD}|${C_RESET} $line"; done
    printf '%b\n' "${C_BOLD}+------------------------------------------------------------------${C_RESET}"
    read -r -p "> " REPLY || { echo; exit 1; }
    if [[ "$REPLY" == q || "$REPLY" == Q ]]; then
        [[ -n "$Q_MSG" ]] && info "$Q_MSG"
        exit 0
    fi
    return 0
}

# What q means in a question. The main menu runs each action in a
# subshell, so there "exit" ends only the action and q leads back.
Q_HINT="q to quit"
Q_MSG="nothing done"

# Asks for a number between 1 and $1; sets CHOICE (0-based).
ask_number() {
    local max="$1"; shift
    while true; do
        ask "$@" "Number (1-$max), $Q_HINT:"
        # 10#: "08" is eight, not an invalid octal number.
        if [[ "$REPLY" =~ ^[0-9]{1,6}$ ]] && (( 10#$REPLY >= 1 && 10#$REPLY <= max )); then
            CHOICE=$((10#$REPLY - 1)); return 0
        fi
        err "'$REPLY' is not a number between 1 and $max"
    done
}

# Asks for a folder, Enter takes the default $1; sets FOLDER. A leading
# ~ means the home of the user who ran sudo, not root's.
ask_folder() {
    local def="$1"; shift
    ask "$@" "Enter for: $def" "$Q_HINT"
    FOLDER="${REPLY:-$def}"
    # shellcheck disable=SC2088  # the literal ~ the user typed
    if [[ "$FOLDER" == "~" || "$FOLDER" == "~/"* ]]; then
        local home
        home="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
        FOLDER="$home${FOLDER#\~}"
    fi
}

confirm() {
    ask "$@" "Type y to go ahead, anything else to stop:"
    [[ "$REPLY" == y || "$REPLY" == Y ]] || { info "nothing done"; exit 0; }
}

# The session's backups folder: the one chosen with f, if any, else
# BACKUP_DIR from the configuration. Actions run in subshells, so the f
# choice lives in SESSION_FILE, not in a variable.
session_backups_dir() {
    local saved=""
    if [[ -n "${SESSION_FILE:-}" && -s "$SESSION_FILE" ]]; then
        saved="$(cat -- "$SESSION_FILE")"
    fi
    printf '%s\n' "${saved:-$(conf_path "$BACKUP_DIR")}"
}

# Sets FOLDER to the session's backups folder, never asking: it comes
# from the configuration or from f. $1 "create" allows a missing folder
# to be created (backup only); otherwise a missing one stops the action.
backups_folder() {
    local create="${1:-}"
    FOLDER="$(session_backups_dir)"
    if [[ ! -d "$FOLDER" ]]; then
        [[ "$create" == create ]] || die "$FOLDER does not exist yet: no backups there (f in the menu to choose another folder)"
        confirm "Backups folder $FOLDER does not exist. Create it?" \
            "(owned by $(operator_owner), $(operator_dir_mode); existing parent folders are not changed)"
        make_operator_dir "$FOLDER"
    fi
    FOLDER="$(cd -- "$FOLDER" && pwd)"
    info "backups folder: $FOLDER (f in the menu to change it)"
}

# Option f: asks for a folder for this session only (s changes the
# configuration for good).
choose_backups_folder() {
    ask_folder "$(session_backups_dir)" "Backups folder for this session" \
        "(each backup is a subfolder <vm>-<timestamp> in it;" \
        " s in the menu changes the default in the configuration)"
    if [[ ! -d "$FOLDER" ]]; then
        confirm "$FOLDER does not exist. Create it?" \
            "(owned by $(operator_owner), $(operator_dir_mode); existing parent folders are not changed)"
        make_operator_dir "$FOLDER"
    fi
    FOLDER="$(cd -- "$FOLDER" && pwd)"
    printf '%s\n' "$FOLDER" > "$SESSION_FILE"
    ok "backups folder for this session: $FOLDER"
}

# Option s: shows the configuration and changes one setting at a time,
# written to the file at once.
interactive_settings() {
    local i key why
    Q_MSG="back to the menu"
    while true; do
        echo
        echo "Settings in $CONFIG_FILE$([[ -f "$CONFIG_FILE" ]] || echo ' (not there yet: defaults)'):"
        for i in "${!CONF_KEYS[@]}"; do
            key="${CONF_KEYS[$i]}"
            printf '  %d) %-14s %s\n' "$((i + 1))" "$key" "${!key:-(empty)}"
        done
        ask_number "${#CONF_KEYS[@]}" "Which setting do you want to change?"
        key="${CONF_KEYS[$CHOICE]}"
        ask "New value for $key (now: ${!key:-empty})" "$(conf_help "$key")" \
            "Enter keeps it, - empties it, $Q_HINT"
        [[ -n "$REPLY" ]] || { info "$key unchanged"; continue; }
        [[ "$REPLY" == - ]] && REPLY=""
        if ! why="$(conf_check "$key" "$REPLY")"; then
            err "$key $why"
            continue
        fi
        if [[ "$key" == BACKUP_OWNER && "$REPLY" == user && "$BACKUP_OWNER" != user ]]; then
            ask "${C_BOLD}${C_YELLOW}DANGER${C_RESET}: with BACKUP_OWNER=user the next backups' VM disks belong to" \
                "${SUDO_USER:-the user who runs sudo} (0600) and are readable WITHOUT sudo by anything" \
                "running as that user: a malicious browser extension, a compromised" \
                "program, a sync client (Nextcloud, Dropbox) uploading the folder," \
                "a backup tool copying them to storage that is not encrypted." \
                "Every key and password stored on the VMs goes with them." \
                "Owners protect nothing on a lost disk: keep backups on LUKS anyway." \
                "Type yes to switch to user, anything else to keep $BACKUP_OWNER:"
            [[ "$REPLY" == yes ]] || { info "BACKUP_OWNER unchanged"; continue; }
            REPLY=user
        fi
        save_setting "$key" "$REPLY"
        printf -v "$key" '%s' "$REPLY"
        # A new default folder replaces a session choice made with f.
        [[ "$key" == BACKUP_DIR ]] && : > "$SESSION_FILE"
        ok "$key saved in $CONFIG_FILE"
    done
}

# Fills BACKUPS with the backups (folders made by save) in $1, the folder
# itself included if it is one, newest first.
find_backups() {
    local dir="$1" with_invalid="${2:-false}" d
    BACKUPS=()
    if [[ -f "$dir/SHA256SUMS" && -f "$dir/domain.xml" ]]; then
        BACKUPS+=("$dir")
    fi
    while IFS= read -r d; do
        if [[ "$d" == *.INVALID ]]; then
            $with_invalid && [[ "$(basename "$d")" =~ $BACKUP_NAME_RE ]] && BACKUPS+=("$d")
        elif [[ -f "$d/SHA256SUMS" && -f "$d/domain.xml" ]]; then
            BACKUPS+=("$d")
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    return 0
}

# Asks for the backups folder, lists its backups, sets PICKED to the
# chosen one. $1 is the action, shown in the question.
pick_backup() {
    local action="$1" i domain state note
    backups_folder
    find_backups "$FOLDER"
    (( ${#BACKUPS[@]} > 0 )) || die "no backups in $FOLDER (a backup is a folder with domain.xml and SHA256SUMS)"
    echo
    echo "Backups in $FOLDER (newest first):"
    for i in "${!BACKUPS[@]}"; do
        domain="$(backup_domain_name "${BACKUPS[$i]}" 2>/dev/null)" || domain="?"
        state=""
        [[ "$domain" == "?" ]] || state="$(domstate "$domain")" || true
        if [[ "$domain" == "?" ]]; then
            note="${C_RED}unreadable domain.xml${C_RESET}"
        elif [[ -z "$state" ]]; then
            note="${C_GREEN}no VM with this name: restore possible${C_RESET}"
        else
            note="${C_YELLOW}the VM exists ($state): restore as a renamed copy (6), or test-boot (3)${C_RESET}"
        fi
        printf '  %2d) %-45s %8s  %b\n' "$((i + 1))" "$(basename "${BACKUPS[$i]}")" \
            "$(du -sh "${BACKUPS[$i]}" | cut -f1)" "$note"
    done
    ask_number "${#BACKUPS[@]}" "Which backup do you want to $action?"
    PICKED="${BACKUPS[$CHOICE]}"
}

interactive_save() {
    local -a doms=()
    local i state note
    # Test VMs are disposable duplicates of a backup: never worth backing up.
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        is_test_vm "$d" || doms+=("$d")
    done < <("${VIRSH[@]}" list --all --name | sort)
    (( ${#doms[@]} > 0 )) || die "no VMs defined on ${LIBVIRT_URI:-qemu:///system}"
    echo
    echo "Virtual machines (only a shut-off VM can be backed up):"
    for i in "${!doms[@]}"; do
        state="$(domstate "${doms[$i]}")" || true
        if [[ "$state" == "shut off" ]]; then
            note="${C_GREEN}shut off: can be backed up${C_RESET}"
        else
            note="${C_YELLOW}$state: shut it down first${C_RESET}"
        fi
        printf '  %2d) %-35s %b\n' "$((i + 1))" "${doms[$i]}" "$note"
    done
    echo
    echo "Tip: for a smaller backup, run 'sudo fstrim -av' inside the VM just before"
    echo "shutting it down: blocks freed by deleted files are then not copied."
    ask_number "${#doms[@]}" "Which VM do you want to back up?"
    local domain="${doms[$CHOICE]}"
    state="$(domstate "$domain")" || true
    [[ "$state" == "shut off" ]] || die "$domain is '$state': shut it down from inside (or Shut Down in virt-manager), then run this again"

    backups_folder create
    cmd_save "$domain" "$FOLDER" ask
}

interactive_verify() {
    pick_backup "verify"
    cmd_verify "$PICKED"
}

interactive_test_start() {
    pick_backup "test-boot"
    local dir
    dir="$(cd "$PICKED" && pwd -P)"
    ask_folder "$(test_base_dir "$dir")" "Folder for the test VM's files" \
        "(a subfolder ${TEST_PREFIX}<vm> is made in it; option 4 removes it)"
    local base="$FOLDER"
    [[ -d "$base" ]] || die "$base is not a folder"
    base="$(cd "$base" && pwd -P)"
    local why avail copy_need ov_line def=o mode
    why="$(overlay_blocker "$dir" "$base")"
    avail="$(df --output=avail -B1 -- "$base" | tail -1 | tr -d ' ')"
    copy_need="$(du -sB1 "$dir" | cut -f1)"
    [[ "$TEST_MODE" == copy ]] && def=c
    if [[ -z "$why" ]]; then
        ov_line="           backup reachable by the hypervisor: yes"
    else
        ov_line="           ${C_RED}not possible: $why${C_RESET}"
    fi
    while true; do
        ask "Test mode (Enter for $def, from TEST_MODE):" \
            "o) overlay  boots the backup's own disks, read-only;" \
            "           what the test VM writes goes to a small file" \
            "           space: about $(human "$OVERLAY_ROOM") in $base ($(human "$avail") free)" \
            "$ov_line" \
            "c) copy     boots a copy of the backup, which is only read once" \
            "           space: about $(human "$copy_need") in $base ($(human "$avail") free)" \
            "$Q_HINT"
        case "${REPLY:-$def}" in
            o|O)
                [[ -z "$why" ]] && { mode=overlay; break; }
                err "overlay not possible here: $why (c for the copy mode)" ;;
            c|C) mode=copy; break ;;
            *) err "'$REPLY' is not o or c" ;;
        esac
    done
    local net=false ndef=n
    [[ "$TEST_NETWORK" == yes ]] && ndef=y
    ask "Start the test VM with a network card? (Enter for $ndef, from TEST_NETWORK)" \
        "n: no network, check it from its console; the original can run meanwhile" \
        "y: same network as the original VM (refused while the original runs)"
    [[ "${REPLY:-$ndef}" == y || "${REPLY:-$ndef}" == Y ]] && net=true
    cmd_test_start "$dir" "$net" "$mode" "$base"
}

interactive_test_clean() {
    local -a tests=()
    local i
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        is_test_vm "$d" && tests+=("$d")
    done < <("${VIRSH[@]}" list --all --name | sort)
    (( ${#tests[@]} > 0 )) || { info "no test VMs ($TEST_PREFIX*, marked by this script) started by option 3: nothing to remove"; exit 0; }
    echo
    echo "Temporary test VMs started by option 3 (backups and original VMs are not touched):"
    for i in "${!tests[@]}"; do
        printf '  %2d) %s (%s)\n' "$((i + 1))" "${tests[$i]}" "$(domstate "${tests[$i]}")"
    done
    ask_number "${#tests[@]}" "Which test VM do you want to remove? (its duplicated disks and TPM state go too)"
    cmd_test_clean "${tests[$CHOICE]#"$TEST_PREFIX"}"
}

# $1 "true": option 6, a renamed copy. The disk folder is asked only
# when an original one is missing (another host, a rebuilt one).
interactive_restore() {
    local copy="${1:-false}"
    if [[ "$copy" == true ]]; then pick_backup "restore as a renamed copy"; else pick_backup "restore"; fi
    local missing disk_dir=""
    missing="$(restore_missing_dirs "$PICKED")"
    if [[ -n "$missing" ]]; then
        ask_folder "$(default_disk_dir "$PICKED")" \
            "The original disk folder is not usable here (missing, or a link in it): ${missing//$'\n'/, }" \
            "Folder for the restored disks (they keep their original file names)"
        disk_dir="$FOLDER"
        [[ -d "$disk_dir" ]] || die "$disk_dir is not a folder"
    fi
    cmd_restore "$PICKED" "$disk_dir" "$copy"
}

interactive_delete() {
    local i note
    backups_folder
    find_backups "$FOLDER" true
    (( ${#BACKUPS[@]} > 0 )) || die "no backups in $FOLDER"
    echo
    echo "Backups in $FOLDER (newest first):"
    for i in "${!BACKUPS[@]}"; do
        if [[ "${BACKUPS[$i]}" == *.INVALID ]]; then
            note="${C_RED}interrupted backup, not usable${C_RESET}"
        else
            note="VM $(backup_domain_name "${BACKUPS[$i]}" 2>/dev/null || echo '? (unreadable domain.xml)')"
        fi
        printf '  %2d) %-45s %8s  %b\n' "$((i + 1))" "$(basename "${BACKUPS[$i]}")" \
            "$(du -sh "${BACKUPS[$i]}" | cut -f1)" "$note"
    done
    ask_number "${#BACKUPS[@]}" "Which backup do you want to delete?"
    cmd_delete "${BACKUPS[$CHOICE]}"
}

# Runs one menu action in a subshell: its die/exit (errors, q, a refused
# confirmation) end only that action, then the menu comes back.
run_action() {
    local rc
    # Not "( ... ) || rc=$?": bash ignores set -e for everything inside a
    # command tested by || or &&, so an action would run past its errors.
    set +e
    ( set -e; Q_HINT="q for the menu"; Q_MSG="nothing done, back to the menu"; "$@" )
    rc=$?
    set -e
    (( rc == 0 )) || err "the action ended with an error (see above)"
    printf '\n'
    read -r -p "Press Enter to go back to the menu " _ || exit 0
}

interactive() {
    [[ -t 0 ]] || die "no terminal: give a command instead (see --help)"
    require_libvirt
    Q_MSG=""
    SESSION_FILE="$(mktemp)"
    trap 'rm -f -- "$SESSION_FILE"' EXIT
    local current
    while true; do
        # Settings (s) are saved by a subshell: read them again each time.
        load_config
        current="$(session_backups_dir)"
        echo
        printf '%b\n' "${C_BOLD}$APP_TITLE $APP_VERSION${C_RESET} - KVM virtual machine backups"
        echo "  Backups folder: $current$([[ -d "$current" ]] || echo ' (created at the first backup)')"
        echo "  Configuration:  $CONFIG_FILE"
        echo
        echo "  1) Back up a VM                           (save)"
        echo "  2) Verify a VM backup                     (verify)"
        echo "  3) Test-boot a VM backup                  (test-start)"
        echo "     starts a temporary test VM from the backup (overlay or copy);"
        echo "     the backup is only read, the original VM is not touched"
        echo "  4) Remove the test VM started by 3        (test-clean)"
        echo "     deletes only the temporary test VM and its files"
        echo "  5) Restore a VM from its backup           (restore)"
        echo "     back to its original disk paths, same name and identity"
        echo "  6) Restore as a renamed copy              (restore --copy)"
        echo "     ${RESTORE_PREFIX}<vm>, new identity, next to the original"
        echo "  7) Delete a VM backup                     (delete)"
        echo "  f) Change the backups folder for this session"
        echo "  s) Settings (saved in the configuration file)"
        echo "  h) Show the help"
        echo "  v) Show the version"
        echo "  q) Quit"
        ask "What do you want to do? (1-7, f, s, h, v, q)"
        case "$REPLY" in
            1) run_action interactive_save ;;
            2) run_action interactive_verify ;;
            3) run_action interactive_test_start ;;
            4) run_action interactive_test_clean ;;
            5) run_action interactive_restore false ;;
            6) run_action interactive_restore true ;;
            7) run_action interactive_delete ;;
            f|F) run_action choose_backups_folder ;;
            s|S) run_action interactive_settings ;;
            h|H) run_action usage ;;
            v|V) run_action version ;;
            *) err "'$REPLY' is not a choice" ;;
        esac
    done
}

# Package that provides command $1 on distribution family $2.
dep_package() {
    case "$2:$1" in
        debian:virsh) echo libvirt-clients ;;  fedora:virsh) echo libvirt-client ;;  arch:virsh) echo libvirt ;;
        debian:qemu-img) echo qemu-utils ;;    fedora:qemu-img) echo qemu-img ;;        arch:qemu-img) echo qemu-img ;;
        arch:python3) echo python ;;           *:python3) echo python3 ;;
        *:numfmt|*:sha256sum|*:stat|*:du) echo coreutils ;;
        *:find|*:xargs) echo findutils ;;
        *:getent) echo glibc ;;
        *) echo "$1" ;;
    esac
}

# Stops with the install command for this distribution when a command
# the script cannot work without is missing. Nothing is installed here.
check_deps() {
    local -a missing=() pkgs=()
    local c family="" id_like="" cmd
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) \
        || die "bash 4.4 or later needed, this is $BASH_VERSION"
    for c in virsh qemu-img python3 numfmt sha256sum stat du find xargs getent; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) && return 0
    # ID and ID_LIKE only: the file is sourced by nothing, read as text.
    [[ -r /etc/os-release ]] && id_like="$(sed -n 's/^ID\(_LIKE\)\{0,1\}=//p' /etc/os-release | tr -d '"' | tr '\n' ' ')"
    case " $id_like " in
        *" debian "*|*" ubuntu "*) family=debian; cmd="sudo apt install" ;;
        *" fedora "*|*" rhel "*)   family=fedora; cmd="sudo dnf install" ;;
        *" arch "*)                family=arch;   cmd="sudo pacman -S --needed" ;;
    esac
    for c in "${missing[@]}"; do
        pkgs+=("$(dep_package "$c" "${family:-debian}")")
    done
    err "missing: ${missing[*]}"
    if [[ -n "$family" ]]; then
        err "install with: $cmd $(printf '%s\n' "${pkgs[@]}" | sort -u | paste -sd' ')"
    else
        err "install the packages that provide them (Debian names: $(printf '%s\n' "${pkgs[@]}" | sort -u | paste -sd' '))"
    fi
    die "see the README, Requirements"
}

bad_args() { err "$1"; echo "Run $(basename "$0") --help for usage." >&2; exit 1; }
# Kept whole for the sudo re-run below, before the options are parsed.
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            [[ $# -ge 2 ]] || bad_args "$1 needs a FILE"
            [[ -f "$2" ]] || die "configuration file $2 not found"
            CONFIG_FILE="$(readlink -f -- "$2")"
            shift 2 ;;
        -V|--version) version; exit 0 ;;
        *) break ;;
    esac
done
case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
esac
load_config
case "${1:-}" in
    ""|save|verify|test-start|test-clean|restore|delete) ;;
    *) bad_args "unknown command '$1'" ;;
esac
check_deps
if (( EUID != 0 )); then
    err "run as root (sudo): disk images, NVRAM and TPM state are not readable otherwise"
    # From a terminal, run again through sudo: sudo asks the password and
    # refuses a user it does not allow. Through bash, so the copy works
    # even without its executable bit. Not exec: this shell stays to drop
    # the cached sudo credentials at the end (sudo -k, no password
    # needed), also after Ctrl-C or a closed terminal.
    if [[ -t 0 ]] && command -v sudo >/dev/null 2>&1; then
        info "running it again through sudo (Ctrl-C to stop)"
        trap 'sudo -k' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM HUP
        rc=0
        sudo -- "$BASH" "$SCRIPT_PATH" "${ORIG_ARGS[@]}" || rc=$?
        exit "$rc"
    fi
    exit 1
fi
case "${1:-}" in
    "")         interactive ;;
    save)       [[ $# -eq 2 || $# -eq 3 ]] || bad_args "save needs DOMAIN, optionally followed by DEST_DIR"; cmd_save "$2" "${3:-}" ;;
    verify)     [[ $# -eq 2 ]] || bad_args "verify needs BACKUP_DIR"; cmd_verify "$2" ;;
    test-start)
        # test-start BACKUP_DIR [--with-network] [--overlay|--copy] [--test-dir DIR]
        t_args=() t_net=false t_mode="" t_dir=""
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --with-network) t_net=true; shift ;;
                --overlay) t_mode=overlay; shift ;;
                --copy) t_mode=copy; shift ;;
                --test-dir) [[ $# -ge 2 ]] || bad_args "--test-dir needs a DIR"; t_dir="$2"; shift 2 ;;
                --test-dir=*) t_dir="${1#--test-dir=}"; shift ;;
                -*) bad_args "test-start: unknown option '$1'" ;;
                *) t_args+=("$1"); shift ;;
            esac
        done
        [[ ${#t_args[@]} -eq 1 ]] || bad_args "test-start needs BACKUP_DIR, optionally --with-network, --overlay or --copy, --test-dir DIR"
        cmd_test_start "${t_args[0]}" "$t_net" "$t_mode" "$t_dir" ;;
    test-clean) [[ $# -eq 2 ]] || bad_args "test-clean needs DOMAIN"; cmd_test_clean "$2" ;;
    restore)
        # restore BACKUP_DIR [DISK_DIR] [--copy], --copy anywhere after BACKUP_DIR
        r_args=() r_copy=false
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --copy) r_copy=true; shift ;;
                -*) bad_args "restore: unknown option '$1' (--name is replaced by --copy since 1.1.0)" ;;
                *) r_args+=("$1"); shift ;;
            esac
        done
        [[ ${#r_args[@]} -eq 1 || ${#r_args[@]} -eq 2 ]] \
            || bad_args "restore needs BACKUP_DIR, optionally DISK_DIR and --copy"
        cmd_restore "${r_args[0]}" "${r_args[1]:-}" "$r_copy" ;;
    delete)     [[ $# -eq 2 ]] || bad_args "delete needs BACKUP_DIR"
                [[ -t 0 ]] || die "delete asks for confirmation: run it from a terminal"
                cmd_delete "$2" ;;
    *)          bad_args "unknown command '$1'" ;;
esac
