# AGENTS.md

Guidance for agentic coding tools working in this repository.

## Project overview

OSMFS ("OSM09 File System") — a tiny, stdlib-only filesystem tool for the
OSM09 6809 retrocomputing platform. It reads/writes a FAT-like image on a fake
SD card image (`fausse_sd.img`, 10 MB) and lets you inject/extract 6809 binary
programs into it.

Layout on the SD image:
- LBA 0: boot sector (not managed by the FS; `format_fs` writes an `OSMF`
  signature at offset 508 **only** when the sector is empty, so bootloaders
  are never touched; `OSMFS_Core.detect()` checks it, then falls back to a
  directory heuristic for pre-signature cards)
- LBA 1-256: root directory (`OSMFS_DIR_SIZE` = 256 sectors x 16 entries)
- LBA 257+: contiguous file data (`OSMFS_DATA_START`)

These constants must match the firmware, `bios/osmfs.asm` (`ROOT_DIR_SIZE`,
`DATA_START_LBA`) in the OSM39 repository this tool now lives in
(`tools/egofs/`). Change both sides in the same commit.

Directory entry: 32 bytes, big-endian (6809):
`+0 status (B)`, `+1 name (15s, space-padded)`, `+16 start LBA (I)`,
`+20 size in bytes (I)`, `+24 boot page (B)`, `+25 boot address (H)`,
`+27 attributes (B)`, `+28 parent folder (H)`, `+30 reserved (2)`.
Parent: 0 = root, else the folder entry's `index` + 1 (`'id'` in
`list_files`). A folder is a size-0 entry with attribute bit5 d (`$27` when
created). Old cards have 0 there: everything is at the root.
Status: `$01` = valid, `$00` = free, `$E5` = deleted. Attributes: bit2=r,
bit1=w, bit0=x, bit3=hidden, bit4=a (OSM-VISION application, linked at
`$4000`), bit5=d (folder).

Behaviour to keep:
- Attributes are masked with `OSMFS_ATTR_MASK` = `0x3F` (bits 4 and 5).
- Names given to `inject_file` / `set_attributes_by_name` may be paths
  (`APPS/GLOUTON.ASM`): missing folders are created (`mkdir`). `list_files`
  gives `name`, `parent`, `id`, `is_dir` and `path`; match on `path`, a bare
  name can exist in several folders. `delete_file` refuses a non-empty folder.
- `inject_file` replaces: valid entries with the same name in the same folder are marked `$E5`
  AFTER the new entry is written (a failure never loses the old version).
  Their sectors are not reclaimed: allocation stays contiguous after the last
  extent, like the BIOS.
- The GUI asks page and address once per multi-file selection and always
  injects with `attr=0x07`: use `egofs_deploy.py` for OSM39 releases.

### Files

- `egofs_core.py` — `OSMFS_Core` class: all filesystem logic (format, list,
  inject, delete, chmod-style attribute set, extract). No UI.
- `egofs_gui.py` — `EgoFS_GUI` class: Tkinter frontend on top of the core.
  Entry point is the `if __name__ == "__main__"` block at the bottom. Accepts
  an optional device path as `sys.argv[1]` (used by the watcher); with that
  argument it pre-fills the device field and auto-connects.
- `egofs_watcher.py` — session daemon that polls `/sys/class/block` for newly
  inserted block devices (whole disks **and** partitions), runs
  `OSMFS_Core.detect()` on each, and launches the GUI with the device path as
  argument. Stdlib-only. The user must be able to read raw devices (add them
  to the `disk` group). Flags: `--scan-existing`, `--gui <path>`,
  `--check /dev/sdb` (read-access + detection diagnostic).
- `egofs_deploy.py` — CLI: injects every file of the OSM39 `dist/SD` with the
  page/address/attributes of `dist/manifest.txt` (written by `deploy_sd.sh`),
  then re-reads the card (one entry per name, fields, byte-identical content).
  Refuses a non-OSMFS device; asks for confirmation unless `--oui`.
- `install.sh` — creates a `~/.config/autostart` entry for the watcher and
  prints the `gsettings` commands to silence the desktop's "unknown
  filesystem" dialog.
- `test.bin` — sample binary used for injection tests. The 10 MB test image
  (`fausse_sd.img`) is NOT in the repository: tests create a blank one.

There is **no packaging config** (`pyproject.toml`, `setup.py`), no `__init__.py`
(a flat module layout — imports are plain `from egofs_core import OSMFS_Core`),
and no dependency list: the project uses only the Python 3 standard library
(`os`, `struct`, `tkinter`).

## Build / lint / test commands

The project has no build system, no linter config, and no test suite. Use the
commands below; if you add tests or tooling, prefer pytest and standard
dev-tooling conventions.

- Run the GUI app (requires a display; on a headless machine use
  `xvfb-run python3 egofs_gui.py`):
  ```
  python3 egofs_gui.py
  ```
- Run the SD watcher (launches the GUI when an OSMFS card is inserted):
  ```
  python3 egofs_watcher.py
  ```
  Use `--scan-existing` to also check disks already present, and
  `--gui /path/to/egofs_gui.py` to override the GUI path. Diagnostics for one
  device: `python3 egofs_watcher.py --check /dev/mmcblk0`.
- Install the session autostart for the watcher:
  ```
  bash install.sh
  ```
- Syntax-check / compile all modules (works as a "build" check):
  ```
  python3 -m compileall egofs_core.py egofs_gui.py egofs_watcher.py
  ```
- Verify the core module imports cleanly:
  ```
  python3 -c "import egofs_core"
  ```
- Run a single ad-hoc test (no framework exists — exercise a core method
  against a throwaway copy of the image so the repo image is never mutated):
  ```
  python3 - <<'EOF'
  open("/tmp/test_sd.img", "wb").truncate(10 * 1024 * 1024)
  from egofs_core import OSMFS_Core
  core = OSMFS_Core("/tmp/test_sd.img")
  core.format_fs()
  assert core.inject_file("test.bin", "TEST", 0, "0xC000") is True
  files = core.list_files()
  assert len(files) == 1 and files[0]["name"] == "TEST"
  assert core.extract_file(files[0]["index"], "/tmp/out.bin") is True
  assert open("/tmp/out.bin", "rb").read() == open("test.bin", "rb").read()
  print("core OK")
  EOF
  ```
- If you introduce a real test suite, name files `test_*.py` and run a single
  test with:
  ```
  python3 -m pytest tests/test_egofs_core.py -k test_name
  ```
- There is no linter/formatter configured. Keep style consistent (see below)
  and do not introduce external dependencies unless asked.

## Code style

The project follows Python PEP 8 with the conventions below. Match the
existing style exactly when editing.

### Imports

- Standard-library only; order: `import` lines first, then `from ... import`
  lines, both alphabetically grouped. Examples already in the code:
  ```python
  import os
  import struct

  import tkinter as tk
  from tkinter import ttk, filedialog, messagebox, simpledialog
  from egofs_core import OSMFS_Core
  ```
- GUI module imports the core module with `from egofs_core import OSMFS_Core`
  (flat layout, no package prefix).

### Formatting

- 4-space indentation; no tabs. Lines under ~88 chars where practical.
- UTF-8 source (non-ASCII characters appear only in strings/comments/docstrings,
  e.g. `é`, `⬇`, `✖` — never in identifiers).
- Blank lines: two between top-level classes/definitions; one inside methods
  where helpful for readability.

### Types

- No type hints or `typing` imports are used anywhere in this codebase.
  Keep new code untyped to match; if you do add hints, add them to new files
  only, not to existing functions.
- Prefer simple stdlib containers (dicts, tuples) over dataclasses/enums;
  file metadata is returned as dicts with the keys:
  `index`, `name`, `lba`, `size`, `sectors`, `page`, `addr`, `attr`, `rwx`.

### Naming conventions

- Classes: `PascalCase` (`OSMFS_Core`, `EgoFS_GUI` — note the existing classes
  are acronym-heavy; keep them as-is).
- Methods, functions, and local variables: `snake_case` (`list_files`,
  `_read_sector`, `next_free_lba`, `file_size_bytes`).
- Private helpers: single leading underscore (`_read_sector`, `_write_sector`,
  `_sectors_for`, `_rwx_str`).
- Constants: `UPPER_SNAKE_CASE` (`self.sector_size`, `self.dir_lba` are set in
  `__init__`; use module-level `UPPER_SNAKE_CASE` for new module constants).
- Identifiers are **English**; comments and docstrings are **French**.
  Do not translate existing French comments.

### Error handling

- Core (`egofs_core.py`): catch exceptions with `try/except` and report via
  `print("[!] ...")` (errors) or `print("[*] ...")` (progress/success);
  return `True`/`False` to signal success/failure.
- GUI (`egofs_gui.py`): errors/success surfaced through `messagebox`
  (`showerror`, `showinfo`, `showwarning`, `askyesno`); guard every action
  method with `if not self.core: return messagebox.showwarning(...)`.
- Do not raise/throw in the core for expected conditions (full directory,
  missing file) — print a `[!]` message and return `False`.

### File I/O conventions

- The disk is always opened fresh per operation (`with open(..., 'rb'/'rb+')`),
  never held open across methods.
- Sectors are 512 bytes (`self.sector_size`); reading/writing always goes
  through `_read_sector`/`_write_sector` which seek to `lba * sector_size`.
- On-disk structures use `struct.pack`/`struct.unpack` with the big-endian
  format string `">B 15s I I B H B 4s"` (= 32 bytes) — never change endianness.
- Directory entries are built from `b'\x00'`-padded/space-padded fixed fields;
  names are ASCII, truncated to 15 chars and left-justified with spaces.
- Boot address strings are passed as hex strings (e.g. `"0xC000"`) and
  converted with `int(boot_addr, 16)`.

## Testing / data safety

- **Never** run `format_fs` or write operations on a real card or on a
  user's image; work on a throwaway file in `/tmp` (see the snippet above).
- If you change the on-disk format or `entry_format`, update the docstring of
  `OSMFS_Core` which documents the layout.
