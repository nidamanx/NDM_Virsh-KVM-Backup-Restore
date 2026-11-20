# Changelog

All notable changes to NDM virsh KVM Backup Restore are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-11-20

### Changed

- With `BACKUP_OWNER=user`, disk images and NVRAM belong to the user who ran `sudo`
  too (`0600`), so user-level backup tools can copy them. The dangers are written out
  in the README (Ownership and permissions), in the menu and in the output of `save`.
- Switching `BACKUP_OWNER` to `user` from the menu (`s`) shows a warning and needs a
  typed `yes`; the backup confirmation says who will be able to read the disks.
- `test-clean` gives the backup's disks back to the owner they had before the test,
  not always to root.

### Added

- Missing commands are checked at start, with the install command for Debian, Fedora
  or Arch.
- Started without root from a terminal, the script runs itself again through `sudo`,
  and drops the cached `sudo` credentials when it ends.
- `test-start` refuses a backup whose disks a previous test left with QEMU's user.

Backups made by 1.1.0 work unchanged.

## [1.1.0] - 2026-10-20

### Added

- Test boot in overlay mode (default: the backup's own disks, read-only, no copy) or
  copy mode, chosen in the menu with the space each one needs; `--overlay`, `--copy`,
  `--test-dir` and the `TEST_MODE` setting.
- Free space shown before every write, with a confirmation when less than 10% of the
  disk would stay free.

### Changed

- `test-clean` puts the backup's permissions back and verifies it again.
- Restore writes each disk back to its original path and file name; every target is
  shown before a typed `yes`.
- `restore --copy` (menu 6, `RESTORE_PREFIX`) replaces `--name`.

Backups made by 1.0.0 work unchanged.

## [1.0.0] - 2026-10-18

### Added

- First release: `save`, `verify`, `test-start`, `test-clean`, `restore`, `delete`,
  interactive menu, configuration file, zstd compression, comparison with
  `qemu-img compare`.

