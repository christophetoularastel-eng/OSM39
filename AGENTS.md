> **Dépôt public** : BBC BASIC (`bbcbasic/`), basic69 et `tools/asm6809`
> ne sont pas publiés ; les jeux y portent d'autres noms (GLOUTON,
> ENVAHIS, BRIQUES, DONJON39). Ce qui en parle ci-dessous vient du dépôt
> de travail.

# AGENTS.md — OSM39 V2

Homebrew HD6309 OS: an 8 KB EPROM BIOS plus programs loaded from an SD card
(custom FS "OSMFS"). Toolchain: lwtools 4.24 (`lwasm --version`) + `objcopy` + `python3`. No CI.

Comments and user-facing strings are **French**; match that.

This file states what is true **now**. History, corrections and fossils live in
`docs/historique.md`. If you find a claim here wrong, fix it here and log the
correction there — do not add "an earlier revision said…" to this file.

**Golden rule: read the emitted bytes (`.lst`, `.map`), not the source. Numbers
quoted in this file (sizes, addresses, counts) are hints; measure before relying
on them.**

## Build

```sh
make                      # bios shell forth cmd asm basic69 osmvision
make -C bios              # -> bios/osm39.bin (8 KB EPROM image)
make -C bios osm39.hex    # debug Intel-hex link
./deploy_sd.sh            # build + verify + fill dist/{EPROM,SD,DEPLOY.md}
./deploy_sd.sh --no-build
```

- `dist/DEPLOY.md` gives, per SD file, the page, address and attributes to set
  in the OSMFS entry (the card is written on the PC with `tools/egofs/`). Addresses are **measured** from each program's `.map` (`.code`), never
  declared: `BASIC` loads at `$5A00`, `SHELL` at `$6000`, everything else at `$0000`. Pages are
  declared in the script: `OSMVISION` page 0 at `$0000`, `SHELL` page 0 at `$6000`,
  every console program AND every OSMVISION application page 1 (the loader
  uses the entry's page; page 0 below `$4000` would overwrite the residents,
  and the script refuses it). Every program links with `--map`; a missing map
  fails the deploy.

- `tools/carte_sd_kbd_son/simule.py`: gate-level simulation of the new
  SD/keyboard/sound board, read from its KiCad netlist (needs `kicad-cli`
  10: the schematics are saved by KiCad 10; on this machine `kicad-cli` is
  `~/.local/bin/kicad-cli`, a wrapper around the Flatpak that must share
  `/tmp`; schematic in `~/Documents/kicad/OSM09/SD-KBD-SON`; the CRT2
  board is `~/Documents/kicad/OSM09/osm09-CRT2`). 6309 bus cycles at
  1.8432 MHz, an SPI-mode-0 SD card, AY bus modes, setup/hold and runt
  checks; `++name` tries a netlist fix from `CORRECTIFS` before editing
  the schematic.
- `tools/crt2/simule_crt2.py`: logic simulation of the CRT2 video board
  from its netlist (same engine as the SD board; behavioural 6845, RAM,
  font EEPROM). Proves the graphic mode (U125 O3 `GRAPH`; U200/U201 feed
  the 166 from `bd`; U202 puts RA0-3 on U112 A11-A14 when the 6845
  reads): text mode pixel-identical to `crt2_avant_graphique.xml`, U112
  sees RA x 2048 + (MA & 2047), graphic pixels and colour come from the
  same cell, CPU writes keep page addressing. U125 scrambles the page:
  D0 -> A14, D1 -> A12, D2 -> A13 (software page 5 = RAM bank 6). Timing
  of the EEPROM/6845 is assumed, not known: text-mode alignment is the
  board's word, not the simulation's.
- Not in the root Makefile: `video/`, `test/` (board bench), `games/`,
  `apps/` (`deploy_sd.sh` builds the last two).
- User manual (French, PDF): `docs/manuel/manuel.html` + `manuel.css` ->
  `tools/manuel/fabrique.py` (WeasyPrint in `tools/manuel/.venv`, fonts in
  `tools/manuel/polices`; it also redraws the font tables with `police.py`).
  Screenshots come from the real software: `./deploy_sd.sh`, then
  `tools/manuel/captures.py` (verifier emulator, VSYNC IRQ, scripted keys,
  VRAM drawn by `ecran.py`). Images and the PDF are outputs, not versioned;
  `docs/manuel/photos/` (3D renders of the board) is.
- `apps/mire.asm` is the **template OSM-VISION application**: version check,
  window, text, input, exit by `RTS`. Start a new app from it. It is also a
  diagnostic tool: shows each key code (`Ctrl+F` should be `$06`), and black
  screens with IRQ on (`N`) / masked (`M`) for the BRIQUES streaks.
  `apps/Makefile` checks `App_Start` is at offset 0.
- Other apps: `apps/envahis.asm` (Envahis: direct VRAM diff
  renderer, raw PS/2 reading through `SCAN_CODE`, high score in
  `ENVAHIS.HI`), `apps/calc.asm` (VisiCalc-like sheet, 26 x 50, cell texts in
  RAM page 3; Esc asks O/N while the sheet is unsaved) and `apps/edit.asm` (WordStar-like editor, gap buffer over RAM
  pages 2-3, files up to 64 KB minus 256 bytes). OSMVISION's "Editer" and "Ouvrir" on .ASM/.TXT/.INC launch `EDIT`.
- `apps/glouton.asm` (GLOUTON, arcade ghost AI, high score in `GLOUTON.HI`):
  maze and glyphs come only from `video/glyphes_glouton.py`, which writes font
  page 1 `$88-$FF` and generates `apps/glout_data.inc` (never edit it).
  Change the maze or a sprite there, rerun the script, reflash the
  character EPROM.
- `apps/donjon39.asm` (DONJON39: walk a 16 x 16 maze in 3D). Ray casting, one
  ray per column of a 64 x 18 view, DDA, wall height in thirds of a row
  (MINITEL's 2x3 mosaics), E/W faces solid, N/S faces checkered, doors
  (map value 8, yellow planks; Space opens the one 3/4 of a cell ahead,
  it closes after 300 frames once the player is out), dotted floor, Tab
  minimap (top right, 8 x 6 cells), D3 = 1 colours. No division: tables.
  - The map is read from `DONJON39.TXT` in the current folder (shipped as
    `GAMES/DONJON39.TXT`, edit it with EDIT; rules in `texte_carte()`),
    else the built-in map; the border is forced to wall.
  - The single source is `tools/donjon39/donjon39.py` (tables, map, and an
    exact integer model of the renderer); `--inc` regenerates
    `apps/donjon_data.inc` (never edit), `--txt` regenerates
    `apps/DONJON39.TXT` from the built-in map, `--vue X Y A` prints a view.
  - Two image buffers in page 1 from `$5000` (the code must end before:
    `apps/Makefile` checks): `Want` (being computed) and `Pret` (being
    shown). `Irq_Donjon`, hooked into `rvec_IRQ` ahead of the BIOS handler
    (restored on exit), copies 4 dirty rows of `Pret` per VSYNC by TFM;
    meanwhile the loop computes the next image, then waits for `Pret` to
    be fully shown, marks the rows of `Want` that differ, swaps. Keys:
    raw PS/2 bytes from the NMI queue `kbd_buf` (held arrows), queue
    emptied and Esc release awaited on exit.
  - Measured in the emulator: ~17 000 instructions to compute an image,
    5 frames per image when turning (copy-bound: 20 rows, 4 per frame).
  - After any change to either side, run `make -C test donjon39`.
- `apps/parole.asm` (PAROLE: French text-to-speech, S.A.M.-style formants).
  Output (since 2026-10-30): the AY as a DAC, tone and noise off, channels
  A + C summed; each sample 0..120 -> a volume pair (`TabA`/`TabC`, chosen
  by `tables_ay()` from `NIVEAUX` of `tools/ay/ay.py`, 80 levels), both
  written back to back with `STD AY_ADR` in the second of the two 128-cycle
  slots; timer 3 of the 6840 stays the 7200 Hz sample clock. The single source is `tools/parole/parole.py`: rules,
  phonemes, prosody, and an exact integer model of the 6309 loop.
  - `--inc` regenerates `apps/parole_data.inc`; `-o x.wav` renders what the
    board will say through the AY (`--6840`: the old timer-2 output).
  - The sample loop is self-modifying: each frame rewrites operands. The
    sine x amplitude table is built at `$7000-$7FFF` at start-up.
  - After any change to either side, run `make -C test parole`.
- Any console program OSMVISION launches (Enter, Exécuter) runs in the
  Terminal window titled with its name (`Term_Ouvre`/`Term_Ferme`); SHELL
  opens the Terminal; only `PleinEcran` names (none since VI was removed on
  2026-10-16) run full screen. FORTH and BASIC use the console only.
- **Terminal** (OSMVISION key T, Space menu): the SHELL, linked at `$6000`
  in page 0 next to OSMVISION, is loaded and called by `JSR`; the BIOS
  console is limited to the window (`sys_Console_Zone`: A col, B row,
  E width, F height, Y attribute; E = 0 back to full screen). `EXIT`
  returns; OSMVISION restarts as after a console program (folder may have
  changed). /BIN commands run in page 1 and print in the same zone.
  - In a zone the IRQ (`Zone_IRQ`) wraps at the right edge, scrolls only
    the zone by copying rows (2 rows per frame, text waits), `$0C` clears
    the zone, BS stops at the left edge, `$80-$83` and other controls are
    ignored. No hardware scroll. `Demarrage` and `Secours` clear the zone.
  - Proven by `make -C test terminal` (BIOS) and `make -C test bureau`
    (T, VER, PWD, EXIT on the real OSMVISION and SHELL).
- **BBC BASIC** (`bbcbasic/`, see its README): Dominic Beesley's 6809/6309
  port of BBC BASIC IV, vendored in `bbcbasic/amont/` (changes marked
  `OSM39`), built with `asm6809` (GPL, `tools/asm6809`, built by the
  Makefile; lwasm and the board's ASM cannot read it). `osm39_mos.asm` is
  the MOS layer (console, `sys_kbd_poll`, OSFILE LOAD/SAVE on OSMFS, `*CAT`
  `*DIR` `*DELETE` `*EXEC` `*HELP` `*BYE`, TIME, INKEY, COLOUR, TAB(x,y),
  open files: 2 channels, channel n held whole in RAM page n+1, 32 KB,
  written at CLOSE).
  - Two binaries: `BBCBASIC` (inline 6309 assembler, from `$2D00`: 9 KB
    of programs) and `BBCPLUS` (`NOASM=1`, from `$3600`: 11 KB);
    `BASE`/`BASE_PLUS` in `bbcbasic/Makefile`, a few hundred bytes left
    below `$8000` in each. `*LOAD`/`*SAVE` move machine code between the
    card and PAGE..BASIC (CALL/USR: A% B% X% Y% -> A B X U). Errors are
    `SWI3` (native frame, PC at `12,S`) through `rvec_SWI3`, restored by
    `*BYE`. Escape = BIOS `kbd_echap`, set by the NMI on PS/2 code `$76`.
  - No license on the upstream: personal use, do not republish.
  - BASIC's stack is at `$01xx` in page 1: a BIOS service that switches
    pages (`FarRead`, `FarWrite`, `FS_LoadFile`/`FS_SaveFile` to another
    page) must run on the system stack (`Om_Sys`), or it reads its own
    frame from the wrong page. `FS_DeleteFile` and `FS_LoadFile` do not
    preserve U.
  - `FS_SaveFile` always creates a new entry: delete the old file first
    (SAVE and CLOSE do).
  - Graphics (`osm39_gfx.asm`): PLOT/MOVE/DRAW/GCOL/CLG/POINT/VDU 29 as
    2x3 mosaics (MINITEL's font page 1 glyphs, `Om_TabMos` = `Tab_Mos40`)
    in the Terminal zone. Pixels never touch VRAM: they queue per-cell
    masks in `gfx_tampon` (512 bytes of BIOS BSS, also the inverse glyph
    table), applied right after a frame tick, 10 cells per frame (CPU
    VRAM access outside vblank flickers on the board). The verifier
    checks every BASIC VRAM write lands early in a frame.
    The verifier's emulator lacks NEGD/ASLD (DIVD/DIVQ were added for
    CALC on 2026-10-27): the code avoids them (scaling = high word of `MULD`).
  - SOUND (`osm39_son.asm`): notes queued in `SND_BUF` for the BIOS
    sequencer (`snd_play` plays a buffer >= `$C000` without copying);
    6840: 2 square voices, channels play one after another. `son_coupe`
    = `$4D` silences it (the verifier's `lance(..., son=0)` enables it).
  - Not yet: OSGBPB, ENVELOPE, simultaneous channels, circles, VDU 24,
    TIME$.
  - Proven by `make -C test bbcbasic` (~10 min).
- `apps/minitel.asm` (MINITEL: Videotex terminal over the serial line, 115200
  baud). The modem is either a real V.23 modem (Olitec Speed'Com 2000,
  checked on 2026-10-27 through a box phone line) or the PC:
  `python3 tools/minitel/modem.py` (`/dev/ttyUSB0`; `3615`... and
  `0972101721` -> MiniPavi `tcp://go.minipavi.fr:516`, `0` = local test
  page, `--pty` for trials). modem.py stays SILENT by default (no echo,
  non-AT lines ignored): any byte received during the 1 s boot window
  opens SECOURS.
  - Call: `ATE0&D0B2M1S91=6DT<n>` (`&D0`: the board has no DTR, pins 4-6
    are looped; `B2` = V.23; `M1` = speaker off once connected; `S91=6`:
    transmit at -6 dBm instead of the default -10: at the default level
    MiniPavi never took our answers over the box line, at -6 the whole
    page came, checked on 2026-10-30). A typed
    `36xx` becomes `0972101721,,,,,`: MiniPavi's phone number answers with
    a voice menu first, the 5 commas (2 s each) let it pass before the
    modem listens (4 were too tight: NO CARRIER, the voice taken for a
    carrier). The AT lines leave with even parity, like the keys. modem.py ignores `B`, `M`, `&D`... and commas.
  - Keys leave as 7 bits + even parity (`Envoie_P`), received bytes lose
    bit 7 (`Vt_Octet`); modem.py strips bit 7 towards Internet. The real
    modem answers with the parity of the AT command (`C3 CF 4E 4E...` for
    CONNECT): its lines are compared with bit 7 stripped.
  - Over the phone, MiniPavi (1) repeats PRO2 START PROCEDURE `1B 3A 69 44`
    every 3 s until it takes an answer `1B 3A 73 44` (it often ignores the
    first ones: `Term_Octet` watches START on the raw bytes, even in PCE,
    answers every one and restarts at block 0), (2) asks ENQROM
    (`1B 39 7B`; answer `SOH C u 4 EOT`, a Minitel 1B), (3) sends
    everything in PCE blocks (error correction, STUM1B): 15 bytes, CRC
    x^7+x^3+1 over the 8 bits of each byte, parity included, MSB first,
    then NUL; a bad block -> `NACK 40+n`, the server answers `SYN SYN
    40+n` and resends from block n. `Term_Octet` (model: `Terminal` in
    `videotex.py`) does all that in front of `Vt_Octet`; a NACK without
    answer is resent after 68 frames. Over TCP (modem.py) there is no PCE.
  - `tools/minitel/capture.py` dials from the PC through the real modem and
    logs the raw bytes (`--terminal`: the PC plays MINITEL with the
    `Terminal` model); `minipavi_pce.vdt` (75 blocks) and
    `minipavi_bruit.vdt` (mangled START: the box line is often noisy,
    VoIP) are such captures.
  - The board's serial connector (OSM09_V3 `J2`) is DTE-wired on a FEMALE
    DE9: a modem needs a straight male-male adapter (never null-modem).
  - Hang-up: 1.5 s silence (`GARDE` = 90 frames), `+++`, 1.5 s, `ATH`.
  - The single source of the decoder is `tools/minitel/videotex.py`: the
    `Ecran` model fills a LOGICAL 40 x 25 screen (code, kind, attribute;
    subset and simplifications in its header); `cellules40`/`cellules80`
    render it. `--police` (70 mosaic glyphs, font page 1 `$07-$1B`,
    `$4F-$7F`), `--inc` (`apps/minitel_data.inc`, never edit), `--png`
    (preview of a capture, `--80` for full screen).
  - Two displays, Ctrl+F toggles: a 40 x 25 OSMVISION window (columns
    19-60, rows 0-26; disjoint mosaics drawn contiguous) and full screen
    80 x 25 (one Minitel column = two cells). Key bar on rows 27-29.
    In G1 mode, `$40-$5F` are mosaics too (the MiniPavi logo relies on
    it). Black foreground is drawn `$8` (every foreground has D3 = 1, i.e.
    attenuated).
  - `tools/minitel/accueil_minipavi.vdt` is a real capture, used as a test.
  - The ACIA runs on E = 1.8432 MHz: CR `$95` = /16 = 115200, the only
    standard rate it can make (`$96` = /64 = 28800 is unknown to a real
    modem). Bytes still arrive at the line rate (~120/s): the modem, or
    modem.py's `--debit`, paces them.
  - After any change to either side, run `make -C test minitel`.
- `scan_keyboard` returns special keys as codes `$80-$8B` (arrows, Home, End,
  PgUp, PgDn, Del, Ins, Ctrl+Home, Ctrl+End): names in `lib/ui.inc`
  (`KEY_*`). AltGr (AZERTY) and keypad `/` and Enter are decoded too.
- **OSMVISION applications run in their own page** (attribute `a`, page 1,
  linked at `$0000`, `App_Start` at offset 0; `games/briques.asm` likewise,
  without `--section-base` because it has a `.bss`). OSMVISION (page 0)
  loads one with `FS_LoadFile` into the entry's page and calls it through
  `sys_Far_Call`; it exits by `RTS` and OSMVISION's page comes back. An entry
  in page 0 is an old app (linked at `$4000`) and is refused with a message.
- Applications cannot see OSMVISION, so each one includes the drawing
  services itself: `include "../lib/vision.asm"` after the entry point (it
  brings `lib/vram.asm`, `lib/snd.asm`, and `lib/snd.inc` if missing), and
  calls `JSR [VIS_TABLE+vis_XXX]` (contract in `lib/vis.inc`; `VIS_TABLE`
  and `VIS_COUNT_ADR` are labels of `vision.asm`). OSMVISION includes the
  same file: one source. The "son coupé" flag (key M) is `son_coupe` in BIOS
  RAM so every copy obeys it. OSMVISION is no longer limited to `$3FFF`.
- A clean `make` with no warnings is necessary, not sufficient. The real checks
  are the verifiers (see below).

## Generated files — never edit

`bios/hardware.inc` and `bios/sysfunc.inc` are generated:
`bios/ram.asm` → `ram.o` → `ram.map` → `update_includes.py` (+ `vectors.asm`).

- `ram.map` is linked from `ram.o` **alone**; the `ram.o` rule depends on
  neither `.inc`. Do not "fix" that: it breaks the dependency cycle.
- The generator writes only on change (idempotent). That is load-bearing; it is
  why `make -q` always reports work pending. Do not touch the files to silence it.
- New global for user programs: add it to `symbols` in `update_includes.py`.

## Adding or reordering a BIOS service

Callers do `JSR [table_function_ram+sys_XXX]`; the table is BSS at `$C000`,
filled at boot from `table_function_rom`. Its size is **fixed at 96 bytes**
(`TABLE_OCTETS` in `update_includes.py`): the unused tail is `table_reserve`,
whose ROM entries are `fdb Sys_Absent` (returns C=1). A new service takes one
reserved slot, so the system RAM after the table (`SCAN_CODE`, `sd_err`...)
never moves and already-built programs keep working. Edit exactly two files:

1. `bios/ram.asm` — `sys_XXX rmb 2` just before `table_reserve` (+ `export`),
   and 2 bytes less in `table_reserve rmb`
2. `bios/vectors.asm` — `fdb XXX` at the same index, before
   `table_function_end` (+ `import`), and one `fdb Sys_Absent` less after it

The generator fails the build on a count or order mismatch, a total size other
than 96, or a reserve whose RAM and ROM counts disagree. Changing
`TABLE_OCTETS` breaks every program on the card. Allowed name
divergences (`KNOWN_DIVERGENCES`): `sys_pager`/`Pager`,
`sys_loadandexec`/`LoadandExec`, `sys_ls`/`ls_cmd`. Any other divergence is an
error: rename the slot to `sys_<Handler>` rather than extending the allowlist.

- Slot 0 is `sys_FS_RenameFile`. The non-blocking key read is `sys_kbd_poll`; the console zone is `sys_Console_Zone` (last used slot;
  2 reserved slots left).
- There is exactly one `sysfunc.inc`: `bios/sysfunc.inc`. Never add a local copy.
- `lib/bioslib.asm` thunks: `bsc_<service>`, one `jmp [...]` each. Not every
  service has one (`video_wait_vsync`, `snd_play`, `snd_stop`, `Far_Call*` do not), and
  `bsc_FS_RenameFil` is truncated — grep `bsc_`, not the service name.
- A feature only the boot path needs (splash, boot jingle) is a direct call, not
  a dispatch slot. Add a `sys_*` slot only when a user program must reach it.

## Conventions

- **Carry = error**: C=1 failure, C=0 success, for every BIOS/FS service.
- Never hardcode a RAM address; take it from `bios/hardware.inc`.
- Shared app sources live in `lib/` (`ui.inc`, `snd.inc`, `snd.asm`,
  `rowaddr.inc`). Anything that emits code is included **after** the entry point.
- **Entry point at offset 0**: `start:`/`Vision_Start` must be first in `.code`;
  `test/Makefile` and `osmvision/Makefile` grep the listing to enforce it.
- External programs check `argc` before `argv[1]`; format names with
  `sys_Format_Filename_83` (15 bytes, space-padded) before any `sys_FS_*`.
- Native-mode interrupt frame is 14 bytes; return PC at `S+12`.
- Casing follows the file being edited (both styles coexist). Grep
  case-insensitively.
- Prefer `FCN` (auto-NUL) for strings. `PSHS`/`PULS` must balance.
- Everything is assembled `--6309`. `lib/` has no Makefile: its files are only
  `include`d by the programs that use them.

### 6309 flag gotchas

- `PULS` and `TFR` do not touch flags: before returning D, `cmpd #0` so Z/N = f(D);
  test a transferred pointer with `cmpy #0`, not `tfr y,d / beq`.
- `CLRD`/`CLRA` clear C: set C **after** them (`clrd / orcc #1`).
- `TFM` leaves W = 0; never chain two `TFM` on the same W.
- Do not assert register-file facts beyond D=A:B, W=E:F, Q=D:W; the 6309 doc is
  not in this tree. Store 16-bit fields and load them with `ldu n,y`.

## lwasm traps (each one was a real bug here)

- `mul` is D = A×B and B is the low half of D: put the constant in A, the value in
  B. To scale a 16-bit value, use an `addr` chain (`bios/splash.asm`).
- `mul x`/`mul y`/`mul u` silently assemble to plain `MUL`. Write bare `mul`.
- **Expressions are truncated at the first space** in `equ`/`fcb`/`fdb`/`rmb`:
  `rmb 16 * 15` reserves 16 bytes. Never put spaces in expressions.
- `<<` is not an operator. Multiply.
- `fcb 1, 2` fails, and the error names expression #1. No space after commas.
- Not valid: `cmpi`, bare `lsl` (use `lsld`), `incu` (use `leau 1,u`), `inc a`
  (use `inca`), `decx` (use `leax -1,x`), `cpy` (use `cmpy`), `ldd #'WW'`.
  `lda #'W'` is valid.
- `std` writes A then B: to fill with one byte, load **both** A and B.
- `,x++` always advances 2, whatever the mnemonic.
- `PSHS`/`PULS` lists use a 2-byte native postbyte; don't hand-decode frames.
- Reference encodings: 5-bit indexed postbyte = `$20+offset`, register in bits 2-0
  (X0 Y1 U2 S3). `TFR` postbyte = src<<4 | dst (D0 X1 Y2 U3). `addr u,d` = `10 30 30`.

## Linker and memory map

The memory map lives only in `docs/memory-map.md`. Change `ram.asm` or the link
script, rebuild, then update that doc. Never add a second map.

- Sections: `.code`, `.bss` (`$C000`, BIOS), `.ram_vectors` (`$DFF0`),
  `.vectors` (`$FFF0`).
- **User program with a `.bss`: omit `--section-base`.** `.code=0x0000` drags
  `.bss` to `$0000` on top of the code, and a second `--section-base` is ignored.
  A user program owns `$0000-$7FFF`; its `.bss` never goes to `$C000`.
- `forth` links raw at `$0000`, `shell` at `$6000`; `basic69` at `.code=0x5A00`,
  `.bss=0x0000`.
- `osm39.filtered.srec` drops the `$DFF2..` records (RAM). Keep that filter.
  `srec2bin.py` maps `$E000-$FFFF` to an exact 8192-byte image.
- **EPROM headroom is a budget**: after any BIOS change, read the `.code` end in
  `bios/osm39.map`. Never compute it by hand.

## Verifiers (`test/*.py`) — run them, don't reason instead

| script | proves | in `make -C test`? |
|---|---|---|
| `verifie_rendu.py` | `splash_draw` writes exactly what the table says, by replaying emitted bytes | yes (stages 2-5) |
| `verifie_remplissage.py` | fill routines stay in `$8000-$8FFF`, return, cover 4096 per pass, write one value | yes |
| `verifie_constantes.py` | no `equ`/`fcb`/`fdb`/`rmb` hits the space or `<<` trap | yes, repo-wide |
| `verifie_negatifs.py` | the three above fail on 18 injected bugs, each with a distinct diagnostic | `make -C test negatifs` |
| `verifie_fs.py` | the real BIOS, with 4 emulated RAM pages and an egofs SD image, loads and saves across pages 2→3, refuses page 4, restores the caller's page, never overlaps files | `make -C test fs` |
| `verifie_asm.py` | the real `asm/ASM` on the real BIOS, sources and INCLUDEs on an OSMFS card: every binary byte-identical to lwasm (6309 test, `asm/test/*.asm`, MIRE, GLOUTON; `tout`: all apps and BRIQUES), entry page/address/attributes, error names file and line | `make -C test asm` (`asm-tout`: ~2 min) |
| `verifie_demarrage.py` | the real BIOS from its reset vector: automatic boot, SECOURS (key, serial, `$AA` ignored), LOAD/RUN/BOOT, card without OSMVISION, TRAP report and warm restart, Ctrl+A; `cmd/MONITEUR` on that report (R, E, M, G) | `make -C test demarrage` |
| `verifie_bureau.py` | the real OSMVISION on the real BIOS with scripted keys: copy/paste across folders (content, page, address, attributes), Ctrl+N, cut/paste, rename to a name that exists only at the root, Space-menu letters, paste over an existing name refused, sound icon (barred / with waves after M), `?` shortcut panel (text, file window untouched, second `?` gives back the exact screen, still there after the Space menu) | `make -C test bureau` |
| `verifie_dossiers.py` | the real BIOS's folders: flat card unchanged, MkDir/ChDir/paths/`..`, two formatted buffers, list filtered by folder, root fallback for reads only, non-empty folder kept, move and cycle refusal; `CD`/`MKDIR`/`PWD`/`RM` binaries; OSMVISION's `Load_Directory`/`Draw_FileList` | `make -C test dossiers` |
| `verifie_farcall.py` | the real BIOS's `FAR_CALL`/`FAR_CALLN`, at `$FFE0` and through `sys_Far_Call*`: callee in its page, registers and carry both ways, caller's page back, nesting, page 4 refused, every reserved slot returns C=1 | `make -C test farcall` |
| `verifie_bbcbasic.py` | the real `bbcbasic/BBCBASIC` launched by the real OSMVISION on the real BIOS: arithmetic, FOR/PROC, RUN/LIST, SAVE+LOAD on OSMFS, SAVE twice = one entry, `*CAT`, an error and recovery, `*EXEC` of an LF text, BBCPLUS: free space, `*LOAD` of a lwasm routine + USR, `*SAVE` round trip, no `[`, graphics read back from VRAM (diagonal, filled triangle and colour, POINT, rectangle + GCOL 3, VDU 29 + relative PLOT), SOUND queue in `SND_BUF` (durations, flush, pitches), OPENOUT/PRINT#/BPUT#, OPENIN/INPUT#/BGET#/EOF#/EXT#, OPENUP/PTR#=, Escape from an endless loop (NMI flag), `*BYE` | `make -C test bbcbasic` |
| `verifie_terminal.py` | the real BIOS console in a zone: real `PrintChar`, real VSYNC IRQ frame by frame; VRAM = a model (wrap, zone-only scroll, BS, `$0C`, ignored codes), nothing written outside, cursor, IRQ length | `make -C test terminal` |
| `verifie_minitel.py` | the real `apps/MINITEL` `Term_Octet` gives exactly `videotex.py`'s `Terminal`: logical screen and bytes sent back (MiniPavi capture, modem test page, random streams; PCE: the real phone capture, its 75 CRCs, blocks with a damaged block or a lost byte and the NACK/SYN recovery, NUL/DLE transparency, STATUS, STOP); then the whole app with a simulated modem (parity in its answers) and keyboard, and a MiniPavi-like server (START until answered, ENQROM, PCE with one damaged block): `ATE0&D0B2M1S91=6DT0972101721,,,,,` for 3615, window = `cellules40`, Ctrl+F = `cellules80`, desktop back around the window, Minitel keys with even parity, ACIA at `$95`, `+++`/`ATH` with guard silences, NO CARRIER, silent modem, exit restores rows 25-29 and `serie_brute` | `make -C test minitel` |
| `verifie_donjon39.py` | the real `apps/DONJON39` with the VSYNC IRQ taken every frame (its `Irq_Donjon`, then the real BIOS handler) and raw PS/2 bytes: at rest, the VRAM view (glyphs and attributes) equals the model for the position/angle/map in memory (10 places, minimap included), every VRAM write inside the IRQ, early (<= 512 bytes per frame), walls not crossed, Esc returns with the key queue empty and `rvec_IRQ` restored; with a tricky `DONJON39.TXT` on the card: map and start = `texte_carte()`, Space opens the door ahead, it closes by itself, Tab toggles the minimap | `make -C test donjon39` |
| `verifie_sdtest.py` | the real `cmd/SDTEST` against an SPI-level SDHC card model on the SD-KBD-SON registers: 80 clocks /CS high, CMD0/CMD8 CRCs, ACMD41 with HCS, OCR, CID, CSD capacity, sector 0, 200 compared reads (missing tokens counted), write + read-back + restore at LBA `$00100000` on O, nothing written on N, no card; spacing between transfers as a lower bound in distinct bus accesses (>= 150 slow, >= 9 fast; 30 slow turns fail) | `make -C test sdtest` |
| `verifie_tele.py` | the real `cmd/TELE` driven by the real `tools/tele/tele.py` over a simulated line (NMI ring in, TDR out): ping, R/W in page 1 (direct), page 2 (FarRead/FarWrite, page restored) and system RAM, call with registers and carry, a BIOS service through the table, bad sum / unknown command / bad length refused, Q leaves raw mode and returns | `make -C test tele` |
| `verifie_aytest.py` | the real `cmd/AYTEST` against a simulated AY: 28/28 read-backs on a sound chip, 26/28 with the two R9 faults shown when R9 reads 0; each listening step's registers and length (A, B, C at period 262, chord, noise, envelope), silence between steps and at the end, ports never outputs; the BIOS sequencer (`snd_play` + the IRQ's `AUDIO_UPDATE`) drives A and C frame by frame for the boot jingle and a score copied from page 1, then silence | `make -C test aytest` |
| `verifie_ayjoue.py` | the real `cmd/AYJOUE` (`lib/ay_joue.asm`) with the VSYNC IRQ taken every frame and a simulated AY: register state frame by frame = `tools/ay/ay.py`'s model (a test song using the whole format, then KOROBEINIKI until Esc), ends by itself, `rvec_IRQ` restored, silence, frame writes inside the IRQ, `son_coupe` zeroes volumes, no argument / missing file / not a song refused | `make -C test ayjoue` |
| `verifie_clavier.py` | the real BIOS with the keyboard 6850 simulated: Caps Lock toggles `kbd_verr`, case of a-z and é è à ç ù flipped, Shift+letter lowercase, digit row/punctuation/Ctrl/AltGr unchanged; the real `handler_IRQ` sends `$ED` then the LED byte two frames later (TDR, RTS low >= 100 instructions, RTS high), `kbd_muet` counted down, CR `$DC` at IRQ exit; the real `handler_NMI` drops the echo while muted and queues a key afterwards | `make -C test clavier` |
| `verifie_parole.py` | the real `apps/PAROLE` binary, run in `asm/emu6809.py`, gives exactly the model's sine table, normalised text, frames and the AY writes of every sample (volume pairs = `tables_ay()`) | `make -C test parole` |

- `test/video.asm` is a dead copy no stage includes (it does not assemble).
- Re-run `negatifs` after touching `splash_draw`, `splash_bandes`,
  `prend_la_main` or `attente`. A traceback counts as a broken verifier.
- Coverage says WHERE, not WHAT. A code-vs-table check cannot see a wrong table.
- **When the board contradicts a green verifier, believe the board and fix the
  verifier's model.**
- Do not wire a verifier into `make -C test` until it passes on the current tree.
- Contrast between foreground and background is checked by eye only.

## The `test/` bench (the only code run on the real board)

```sh
make -C bios
make -C test STAGE=stage1_bandes
make -C test send STAGE=...
```

On the machine: RESET, press a key within ~1 s (or send a character on the
serial line) to get `SECOURS>`, then `LOAD`, paste `TEST.hex` on the serial
line, `RUN 0000`; RESET to leave. Run stages 1 → 5 in order; stage 4 is deliberately broken.
`stage6_mire` and `stage7_bureau` are separate, for the BRIQUES well streaks:
three ~8 s phases each. 6 = black, colour bands, black (writes vs pipeline);
7 = BRIQUES row with dithered desktop, plain desktop, dither alone (noise);
8 = black + one colour row (row 1, row 12), then every other row (address glitch).

- `LOAD` is a serial Intel-hex paste with 128 bytes in flight max. A beep means
  dropped characters: resend slower.
- **The bench makes zero BIOS calls** (the board's EPROM is an older build) and
  touches only `$A120` and `$8000-$9FFF` (V4: colours at `$9000`). Needing a BIOS routine means the test
  belongs in `bios/`.
- The BIOS interrupts are still live: `prend_la_main` masks IRQ+FIRQ first and
  never restores CC.
- One source file per stage (lwasm rejects `equ` in conditions). `test/TEST` is
  shared by all stages: check the printed `ETAPE =` line and the byte count.
- `ATT_TOURS` 600 ≈ 2 s (cycle count). Frame = 16 ms. `$A120` is write-only, so
  `attente` cannot be rewritten against a frame counter.

## Video

- 68B45 CRTC at `$A100/$A101`. **V4 hardware (since 2026-10-10, the board
  carries "OSM39 V4.00")**: U126 A0 is wired to a12, so characters are at
  `$8000-$8FFF` and colours at `$9000-$9FFF`.
  - The colour of a cell is the character address + `VRAM_COL_OFS`; use
    `VRAM_COL`/`VRAM_COL_END` for whole-plane loops.
  - The write-only 74HC374 at `$A120` keeps only the page (D0-D2). D3-D5 are
    ignored: no plane select, no `$10` "display mode".
  - Writes still go in vertical blank with IRQs masked: a CPU access glitches
    the picture.
  - V3 software, which wrote `$08` to reach the colours, is NOT compatible.
  - `video/carto.txt` is the authority: a V4 header first, then the V3
    description.
  - U126 pin 4 (/E0, active-low `/8000-9FFF`; the bar is missing on the CRT2
    schematic) was floating until 2026-10-10. It is now wired, so U126 is
    enabled only during CPU accesses.
  `video/carto.txt` is the authority.
- **Display is 80 × 30 rows** (`R6 = R7 = $1e`, since 2026-10-10), 8×16 cells,
  525 lines total (`R4=$1f`, `R5=$0d`). That is VGA 640×480: the picture starts
  45 lines after vsync, and the monitor shows all 30 rows.
  - The software still works in 80×25 (`VIDEO_ROWS equ 25`). Rows 25-29 are
    displayed and cleared by `video_clean`, which fills the whole 4 KB, but are
    not otherwise managed.
  - The BIOS console scrolls on 30 rows (2400 bytes per screen, 1696 = 4096 -
    2400).
  - With the old `R7 = $1d`, row 0 fell outside the monitor's window: that was
    the "black first row".
  - Tune live with MIRE key V (R5, R6, R7, start address).
- Start address `R12/R13 = $FFFF` and `SCREEN_START_OFFSET = -1`: presumed
  compensation of the serialiser pipeline. Do not change without a board check.
- `R10 = $cd` = cursor blink ×1/16 (barely visible). `$0d` = steady. OSMVISION
  hides it (`$2D`) and shows it (`CURSEUR_VISIBLE` = `$6D`, blink ×1/32, in
  `lib/ui.inc`) while a console program runs; MINITEL shows it on CON.
- Attribute byte: D0-D2 foreground (D0 blue, D1 green, D2 red), D3 = 1
  ATTENUATES the foreground (measured on the board on 2026-10-17 with
  `BASIC/LUMIERE.BAS`). CRT2: each colour = HCT08 -> 470 ohm -> monitor
  75 ohm (~0.69 V, VGA nominal); D3 (Vlum0) turns on a 2N7000 that adds
  150 ohm to ground (~0.48 V). Lowering R1-R3 would darken, not brighten.
  D4-D6 background,
  D7 font page. No blink, no invert. `anda #$0F` in `splash_bandes` is
  load-bearing. No foreground is legible on all eight backgrounds.
- **Two hardware display defects** (found 8-9 Oct. 2026, `test/stage6-8` and
  `apps/mire` keys T/P). (1) A one-pixel fringe just before a cell whose
  attribute differs from its left neighbour. (2) Cells whose **foreground is
  0** (attribute bits 0-3 = 0) show fixed pink dotted vertical streaks when the
  same scanlines carry content elsewhere (desktop, windows); invisible on an
  all-black screen. It is NOT caused by U126 /E0 floating (that pin was
  wired on 2026-10-10 and the streaks remain in MIRE). Workaround: for a
  blank black cell use foreground `$8`
  (`$20`/`$08` looks identical). BRIQUES `COLOR_BOARD` does. Root cause (colour
  path, fg = 0) not probed. The most likely suspect is the board itself:
  hand-wired patches and crosstalk. Do not hunt it in software; keep the
  workaround.
- Character generator: EPROM, 8×16, 2 pages × 256 (`font_osm39.bin`, 8192 bytes).
  Page 0 = ASCII (caps rows 2-11), page 1 = semigraphics (rows 0-15). Nothing loads
  the font; that is correct. Page 1 owners are listed in `lib/ui.inc`; the
  last free cells `$1C-$1F` hold OSMVISION's icons and the pointer arrow
  (`video/glyphes_ui.py`). After a font change, reprogram the character
  EPROM with `video/font_osm39.bin` (`deploy_sd.sh` copies it to `dist/EPROM`).
- `handler_IRQ` drains **8** characters per VSYNC. Fast painting = direct VRAM
  writes with IRQ/FIRQ masked; `video_wait_vsync` needs IRQ **on**.
- Splash: `bios/splash.asm` is NOT linked into the EPROM (removed from
  `bios/Makefile` SOURCES on 2026-10-10 to make room for folders; the test
  bench still assembles it). Relinking it needs ~611 bytes. `splash_screen` must keep its final
  `lda #$0C / jsr PUTCHARV` (the only screen reset before the prompt).

## SD card / OSMFS

- No superblock: LBA 0 boot (`OSMF` at offset 508), root dir LBA 1-256
  (`ROOT_DIR_SIZE = 256` sectors × 16 entries of 32 B). Files contiguous; new
  files start at `DATA_START_LBA = 257`, placed after the last used extent.
- The card is written on the PC by `tools/egofs/` (`egofs_gui.py` on top of
  `egofs_core.py`; its own `AGENTS.md`). Its OSMFS constants must match
  `bios/osmfs.asm`. Release path: `./deploy_sd.sh` then
  `python3 tools/egofs/egofs_deploy.py /dev/sdX` (applies `dist/manifest.txt`,
  replaces existing names, sets bit 4, re-reads the card). Test it on a blank
  image in `/tmp`, never on a device. The GUI still injects `rwx` with one
  address per batch: `CHMOD <NAME> +a` is then needed on the machine.
- Entry: `+0` status (`$01`/`$00`/`$E5`), `+1` name (15 chars, no extension),
  `+16` first LBA (BE), `+20` size (BE), `+24` page, `+25` address (BE),
  `+27` attributes (bit0 x, bit1 w, bit2 r, bit3 hidden, bit4 app, bit5 d),
  `+28` parent folder (BE: 0 = root, else the folder entry's number + 1,
  number = (LBA - 1) * 16 + slot). `+30-31` reserved; `FS_FindNext` writes the
  entry's number + 1 there in its COPY (`g_find_fileInfo+30`).
- **Folders** (`bios/osmfs.asm`, header comment): one flat table of 4096
  entries; a folder is a size-0 entry with attribute d. A card from before
  folders has 0 everywhere: everything is at the root.
  - Current folder: `fs_dossier` (BIOS RAM), shared by the shell, OSMVISION
    and every program. Services: `sys_FS_ChDir` (X = path string),
    `sys_FS_MkDir` (X = formatted name), `sys_FS_Dossier` (D = number, or
    `$FFFF` to read), `sys_FS_DirInfo` (D = number -> parent, name in Y).
  - `Format_Filename_83` accepts a path (`../LIB/UI.INC`, `/APPS/X`): it
    resolves the folders and records the buffer (address, page, the 15 bytes)
    in `fs_slots` (4); every `FS_*` taking that buffer uses that folder.
    Existing programs (CP, MV, RM, TYPE, EDIT...) get paths for free. A buffer
    rewritten by hand falls back to the current folder.
  - A READ of a name without path (`FS_FindEntry`, `FS_LoadFile`,
    `FS_GetAttributes`) not found in the current folder retries in `/BIN`,
    then at the root (like a PATH): programs live in `/BIN` and run from any
    folder. Writes, deletes, renames, `FS_FileInfo`, `FS_SetLoad` never fall
    back.
  - `FS_FindFirst/Next` and `FS_ListRoot` list only the current folder.
    `FS_DeleteFile` refuses a non-empty folder; `FS_RenameFile` also moves
    (the new name's folder; `"LIB/"` keeps the name) and refuses a cycle.
  - Commands: `cmd/CD`, `MKDIR`, `PWD`, `LS [folder]` (and `RM` for an
    empty folder). The shell has no built-in `LS` any more.
    OSMVISION lists folders first with the `$80/$81` icon, `..` on top
    outside the root; Enter goes in.
  - OSMVISION's status bar shows the sound state as an icon (page 1
    `UI_HP` + `UI_HP_ONDES`, or `UI_HP_MUET` after M). `?` opens or closes
    a shortcut panel at the right of the desktop (columns 52-79, `AideOn`),
    redrawn after `Draw_Base_UI` (`Aide_Si`).
  - **Clouris** (the user's touch mouse: 6 nails + a palm plate at GND,
    one 74HC14 per nail, outputs on AY port A, J104 of SD-KBD-SON; touch =
    bit 1): IOA0 up, 1 right, 2 down, 3 left, 4 centre, 5 thumb click;
    at rest R14 = `$C0`, `$FF` (nothing plugged) = no contact.
    `lib/clouris.asm` `Clou_Lit` (once per frame: contact seen on 2
    frames, a step at once then every 3 frames after 12, edges for
    centre/thumb). OSMVISION's `Event_Loop` polls `sys_kbd_poll` (dropping
    the queue on entry like `scan_keyboard`) and reads the Clouris each
    frame; pointer `UI_FLECHE` in yellow over the cell's background,
    removed before any action (`Ptr_Cache`), redrawn when idle. In the
    list (cols 11-46) the hovered row becomes the selection, blue as with
    the keyboard (`Ptr_Survol`), and the thumb opens it; pushed against
    the first/last visible row, the list scrolls (`Ptr_Bord`); on the
    scroll arrows (col 47, rows 7 and 23): page. Centre = Space menu: the
    pointer stays, the hovered item is selected (`Menu_Survol`), thumb
    runs it (outside the items: closes), centre closes. Tools: `cmd/CLOUTEST`, `tools/tele/clouris.py` (live, via
    TELE). Proven by `make -C test bureau`.
  - OSMVISION is a file manager: the Space menu (11 items) and Ctrl
    shortcuts — Copier `C`/Ctrl+C, Couper `U`/Ctrl+X, Coller `L`/Ctrl+V,
    Nouveau dossier `N`/Ctrl+N, plus Renommer, Supprimer... The clipboard is
    a name + its folder number; Coller rebuilds the full path
    (`Clip_Source`) and copies through RAM pages 2-3 (64 KB max, page,
    address and attributes kept) or moves with `FS_RenameFile`. Name checks
    use `FS_FileInfo` (no root fallback). A folder can be cut, not copied.
  - Enter on a file opens it by extension (`ExtTable`): `.ASM`/`.TXT`/`.INC`
    -> `EDIT NAME`, `.CAL` -> `CALC NAME`, `.MUS` -> `AYJOUE NAME` (CALC loads the sheet given in
    `argv[1]`).
  - Layout shipped by `deploy_sd.sh`: `OSMVISION` alone at the root (the
    boot loads it from there); `BIN/` system programs plus EDIT and CALC
    (OSMVISION runs them by bare name to open .ASM/.CAL files, and reads
    only fall back to /BIN then the root); `APPS/` applications; `GAMES/`
    games; `BASIC/` BBC BASIC texts (`bbcbasic/BAS/`, load with
    `*EXEC`); `DOC/` text quick references (`apps/EDIT.TXT`, `apps/CALC.TXT`,
    the full manual is `docs/manuel-edit-calc.md`: keep the three in step); `SRC/` sources, with `LIB/` and `BIOS/` for their INCLUDEs
    (`CD SRC`, `ASM GLOUTON.ASM /GAMES/GLOUTON`); `MUSIQUE/` songs for AYJOUE; `BUDGET/` created empty
    (`DOSSIERS` in the script -> `dist/dossiers.txt`).
  - `egofs_deploy.py` erases the old copy of a manifest file that moved
    (same name at the root or in a folder the manifest fills), never in
    the user's folders, and creates the `dossiers.txt` folders. Tried on
    an old-layout image with user files.
  - Programs in `APPS/`/`GAMES/` run from OSMVISION (current folder) or
    by path in the Terminal; PONT finds PONT2/PONT3 in the current folder.
  - Proven by `make -C test dossiers` (BIOS, commands, OSMVISION's list).
- Files go on the card through OSMFS (`FS_SaveFile` / `SAVE`), never by `cp`.
- **Boot is automatic, like a PC** (`Demarrage` in `bios/main.asm`): at reset,
  jingle, banner, then a ~1 s window (60 frames). A keyboard make code (not
  `$AA`/`$FA`/`$F0`) or any serial character in that window opens the
  **SECOURS**; otherwise `KERNEL_FILENAME` (currently `OSMVISION`) is loaded to
  page 0, `$0000`, and relaunched whenever it returns. Not found: SECOURS.
  No card (`Init_SD_Card` returns C=1, `sd_absente`): "Carte SD absente ou
  muette", straight to SECOURS; `BOOT` there retries the card init. Every
  wait in `Init_SD_Card` is bounded, and CMD8 must echo `$AA` (so an SD v1
  card, which rejects CMD8, is refused cleanly rather than hanging).
- **SECOURS** is the only monitor left in the EPROM: `LOAD` (Intel hex pasted
  on the serial line), `RUN aaaa`, `BOOT`. Ctrl+A on the serial line reaches
  it from anywhere (`break` in `IT.asm`). Everything else moved to the card:
  `MONITEUR` (`M`/`E` memory with `[page:]aaaa`, `G` call through FAR_CALL,
  `R` last TRAP report, `Q`) and `LS`. The retired services `sys_reg_cmd`,
  `sys_ls`, `sys_PrintFileName83` keep their slots and return C=1.
- **TRAP** (`handler_TRAP`): copies the frame, stack, video and input state
  to `trap_frame`/`trap_info` (layout in `bios/ram.asm`), prints one line
  (`TRAP 6309  PC=xxxx`, bytes from PC-2), waits for a key, then jumps to
  `Redemarrage` (`vectors.asm`): everything `__start` does except clearing
  the BSS, so the report, `fs_dossier` and `boot_chaud` survive; the window is
  skipped and OSMVISION is reloaded from the card. `MONITEUR R` shows the
  report. A cold reset clears it.
- Proven by `make -C test demarrage` (cold boot, key/serial/`$AA` in the
  window, LOAD/RUN/BOOT, card without OSMVISION, TRAP and warm restart,
  Ctrl+A, MONITEUR on the saved report).

## Hardware facts not derivable from the code

- User RAM: 4 pages × 32 KB at `$0000-$7FFF` via write-only latch `$A0C0`. Nothing
  checks a page number is 0-3; nothing tracks which program owns which page.
- `FS_LoadFile`/`FS_SaveFile` (A = page) continue at `$0000` of the NEXT page
  when they reach `$8000`, for files up to 64 KB, and fail beyond page 3. A
  BIOS older than 2026-10-10 writes straight past `$7FFF` into the VRAM and I/O.
- Calls between RAM pages: `JSR [table_function_ram+sys_Far_Call]` (A = page,
  X = address) or `sys_Far_CallN` (A = page, B = function number in the `FDB`
  table at `$0000` of that page). Source: `bios/farcall.asm`. The same
  routines are also at fixed ROM addresses, `JSR FAR_CALL` (`$FFE0`) and
  `JSR FAR_CALLN` (`$FFE3`).
  - The callee gets B/X/Y/U/W and runs in its page (`current_page`
    follows). The caller gets D/X/Y/U/W/CC back, in its own page. Calls
    nest. Page > 3 gives C=1 with no call.
  - The fixed ROM jump table (`.romjmp`) is append only, up to `$FFEF`.
  - Demo: `apps/pont.asm` plus page modules `PONT2`/`PONT3`, linked at
    `$0000` with `Module_Table` at offset 0 (`apps/Makefile` checks it).
- **The SD card is on the hardware SPI of the SD-KBD-SON board** (`bios/SD.asm`,
  since 2026-10-30; the old socket on PIA port B is no longer used, `main`
  still initialises the PIA): `SD_CTRL` (`$A140`, write-only latch: bit 0 =
  /CS, bit 1 = fast, i.e. E = 1.8432 MHz instead of E/16; copy in `sd_ctrl`)
  and `SD_DATA` (`$A148`: a write sends the byte; a read returns the byte
  received by the PREVIOUS transfer and starts a transfer that sends THAT
  byte back: measured on the board, the 165 also loads on reads, unlike the
  schematic and `simule.py`). Harmless while the card talks; but a `00`
  echoed after CMD24's R1 is taken as the start of the block, so CMD24 is
  sent blind (8 x `$FF` written, R1 never read; the data response tells
  success). No busy flag: at least 9 bus cycles between accesses fast, 150
  slow (`simule.py`); init runs slow, everything else fast.
  - Measured with the driver run from RAM through TELE
    (`tools/tele/essai_bios_sd.py`): 51 200 sector reads without an error,
    ~52 KB/s, 20/20 random writes read back.
  - `cmd/SDTEST` (in `/BIN`) tries the card standalone: init, CID/CSD,
    sector 0, 200 reads, optional write at LBA `$00100000` (content
    restored); every response printed in hex.
- **AY-3-8910 on the SD-KBD-SON board**: write `AY_ADR`
  (`$A150`) selects the register, write `AY_DATA` (`$A151`) writes it, read
  `AY_ADR` reads it back. Clock = E (1.8432 MHz): tone period = 115200 / f
  (A 440 = 262). Ports A/B go to J104. On this board, R9 (channel B volume)
  always reads back `00`; every other register reads back right (300 random
  read-backs through TELE). R9 really keeps nothing: channel B is silent
  (by ear, and pin 3 stays at ~90 mV at volume 15). A and C, tone, noise,
  envelope work (heard with `BIN/AYTEST`). The chip is faulty: until it is
  replaced, music has two voices (A, C); a new chip must show 28/28.
  Output: line level on J103 (LM386 not fitted, R105 = 0 ohm) to the
  monitor amplifier, in place of the 6840.
  - The BIOS sequencer (`snd_play`, so the boot jingle, BBC BASIC SOUND,
    the apps) plays every score on BOTH the 6840 and the AY: voice 1 on
    channel A, voice 2 on channel C, volume 15 (`Ay_Note`/`Ay_Silence` in
    `bios/audio.asm`). Same score format: 6840 count N -> TP = (N+1)/8,
    capped at `$FFF`; note 0 = volume 0. `snd_play` and the end of a score
    put R7 back to `$3A` (tones A and C, no noise, ports input).
    Proven by `make -C test aytest`.
  - Music player (`cmd/AYJOUE <song>`, `MUSIQUE/*.MUS`, Enter on a `.MUS`
    in OSMVISION): `lib/ay_joue.asm` hooks `rvec_IRQ` (like DONJON39), plays
    one frame per VSYNC from the program's own page (no copy, no size
    limit; no FAR_CALL to another page while it plays), `AyJ_Arrete`
    restores the vector. Per voice: instruments with a volume per frame,
    noise, hardware envelope; durations, ties, loops. `son_coupe` = `$4D`
    zeroes the volumes. Don't mix it with `snd_play`.
  - The single source is `tools/ay/ay.py`: text score (syntax in its
    header) -> song file, the exact frame-by-frame model of the player,
    `--wav` (`--b-muette` for this board's chip). Songs live in
    `tools/ay/morceaux/*.txt`; `make -C cmd` compiles them to `.MUS`.
  - After any change to either side, run `make -C test ayjoue`.
- Every OSMFS block access goes through `Fs_ReadBlk`/`Fs_WriteBlk` (4 tries):
  a hand-wired card used to miss a sector. The data-token wait is 20 000
  reads (~400 ms), the write busy wait 40 000 (~0.8 s).
  - Diagnostics (with `MONITEUR`): `M C879` = last SD error code (`sd_err`),
    `C87A` = retries since boot (`sd_retry`).
  - A long transfer shows a spinner top-right (`L`/`E`, then `| / - \`).
- Reading a file piece by piece (files are contiguous): `sys_FS_FileInfo`
  (X = name, Y = 14 bytes: entry `+16..+29`), then `sys_FS_ReadSector`
  (X = 4-byte LBA, Y = 512-byte buffer). `sys_FS_SetLoad` (X = name, A = page,
  Y = address) rewrites an entry's load page and address.
- `FarRead`/`FarWrite` copy via `TFM` with IRQ/FIRQ masked and
  restore the caller's page.
- Sound: 6840 outputs O2 and O3 (gates grounded, clock E = 1.8432 MHz),
  10k each into one node, 4k7 + 47 nF to ground (fc ~1.4 kHz), then to the
  monitor amplifier. Sampled sound works (`apps/son.asm`, validated by ear on
  the board):
  - timer 2 single-shot (CR2 `$A3`): `STD TIMER2` emits one pulse of N E-cycles;
  - timer 3 continuous with its output masked (latch 127) is the sample clock:
    poll status bit 2, then read `TIMER3` to clear the flag;
  - 14.4 kHz carrier, two pulses per sample, so 7200 samples/s at 0-120.
  At 7.2 kHz the carrier whistles. IRQ must stay masked while playing.
  Restore the timers as `init_audio` does afterwards.
- **Remote control (`cmd/TELE` + `tools/tele/tele.py`)**: launched once in the
  Terminal (Esc on the keyboard quits), TELE answers framed commands on the
  serial line (raw mode): ping, read/write memory (page 1 direct, other pages
  via FarRead/FarWrite, `>= $8000` direct, I/O included), `JSR` with A B X Y U
  loaded and all registers returned. TELE ends before `$1000`: test code goes
  in page 1 from `$1000`. SECOURS cannot be driven remotely: `read_line`
  reads the keyboard only (only `LOAD`'s hex comes from the line).
- The console (`PrintChar`) writes to the screen only, never to the serial
  line (since 2026-10-15): the line belongs to programs. In SECOURS, the PC
  terminal sees nothing; `LOAD` still reads the pasted hex.
- Serial raw mode (`handler_NMI`): when `serie_brute` <> 0, each received
  byte goes into the 256-byte ring `serie_buf` (`serie_tete` written by the
  NMI only, `serie_queue` by the program only; full ring: byte lost), with
  no line buffer and no Ctrl+A. `Demarrage` and `Secours` clear the flag.
  A program sends by polling `SR` bit 1 then `STA TDR`. Proven by
  `make -C test demarrage`.
- Keyboard: PS/2 behind a second ACIA at `$A180/$A181`, on the SD-KBD-SON
  board (`J1`: 1 +5 V, 2 data, 3 clock, 4 GND; RTS low holds the clock
  through D1). The CPU board's ACIA at `$A1C0` is no longer used. Both ACIAs share the
  edge-triggered NMI: `handler_NMI` loops over both until neither has a
  byte (serving one then `RTI` left the other stuck until the next frame).
  - The NMI puts each PS/2 byte in `SCAN_CODE`/`NEW_CODE` (raw readers:
    ENVAHIS, the boot window) AND in a 16-byte queue `kbd_buf`.
  - `sys_kbd_poll` (non-blocking) processes the queue and returns the
    character or 0; `scan_keyboard` loops on it (never returns 0) and
    drops the queue on entry if `NEW_CODE` = 0 (someone read raw).
  - The character comes on key RELEASE, only if the released code is the
    last make code, and once (`appui_attente` bit of `key_on`).
  - The host can talk to the keyboard: the ACIA's TxD is on DATA and TxC
    on CLOCK, so `Kbd_Envoie` puts the byte in TDR, holds CLOCK low with
    RTS (CR `$1C`, via D1) ~200 µs (the 6850 outputs its start bit), then
    releases it (CR `$5C`) and the keyboard clocks the 11 bits (CR_key is
    already 8 bits + odd parity, /1). The echo of our frame and the `$FA`
    (read one bit late as `$F4`, the ACK bit taken for a start bit) are
    thrown away by the NMI while `kbd_muet` <> 0. Tried on the board on
    2026-10-31 (`tools/tele/essai_leds.asm`: Caps Lock LED on, then off).
  - Caps Lock (`$58`, on release) toggles `kbd_verr` bit 2 and asks for the
    LEDs; the VSYNC IRQ (`Kbd_Voyants`) sends `$ED`, then 2 frames later
    the LED byte. With it, letters only change case: a-z <-> A-Z and
    Latin-1 `$E0-$FE` <-> `$C0-$DE` (é è à ç ù -> É È À Ç Ù), not ÷ ×,
    not the digit row, not Ctrl or AltGr. Proven by `make -C test clavier`.
  - The keyboard tables give accents in Latin-1 (é = `$E9`) while the
    screen font is CP437 (é = `$82`): accented letters typed in EDIT are
    not drawn as accents (known, not fixed).
  - A program that is busy for a frame (MINITEL) must use `sys_kbd_poll`:
    with one slot, a late reader lost make codes (keys came out one key
    late). Decoding in `keyboard.asm` is ordinary PS/2.
- `LDMD #$01` in `__start` enables native mode. `IT.asm` owns all handlers
  (VSYNC IRQ via 68B40, NMI, TRAP; `trap_active` guards recursion).
- Read `docs/rapport-hd6309-natif.md` before changing interrupt or timing code.

## Emulator (`asm/`, run from inside `asm/`)

```sh
python3 emu6809.py --selftest     # decoder regression, the only reliable mode
python3 emu6809.py --dis <bin> <origin>
python3 ../decode_trap.py PC=.... OP=....
```

- CC bits are I `$10`, H `$20`, F `$40`, E `$80` (fixed on 2026-10-30: H
  and I were swapped, so an add with half-carry masked IRQs at random in
  every verifier that takes IRQs; `ADDD` no longer touches H; `RTI` no
  longer pulls S).
- Fixed on 2026-10-10: `BSR`/`LBSR` pushed a return address 1 or 2 bytes
  early; `A,R`/`B,R` offsets were unsigned (they are signed); `SUBD #` and
  `JMP` direct were missing. The selftest is unchanged by these fixes.
  `test/verifie_parole.py` adds the few 6309 instructions PAROLE uses.
- `verifie_fs.Machine` also runs AIM/OIM/EIM/TIM, the bit ops (BAND...
  STBT), ADCR/SBCR 16-bit, `LDQ #` and native `SWI3` (BBC BASIC uses them).
- Stack pushes/pulls go through `rd8`/`wr8` (paged RAM): before 2026-10-16
  `PSHU`/`PULU` below `$8000` bypassed the page, so FORTH's data stack
  (page 1) computed `2 3 + .` = 2 in the emulator only.
- `emu6809.py` alone lacks most 6309 instructions and its `SYS_*` offsets are
  stale. `test/verifie_fs.py`'s `Machine` adds banked RAM, the SD card and the
  6309 instructions the BIOS and ASM use; build on it, not on `emu6809.py`.
- Selftest fixtures `asm/test*.bin` are committed references, byte-identical to
  `lwasm --format=raw --6809`. Never delete them with a `clean`.
- `dbg.py` and `decode_trap.py` hardcode addresses: update them after relinking.

## Native assembler (`asm/asm.asm` -> `ASM`, page 1)

`ASM <source> <output> [origin hex]` on the machine. Its output must be
byte-identical to `lwasm --format=obj --6309` + `lwlink --format=raw`; that is
what `make -C test asm` proves. GLOUTON takes ~16 M instructions (~45 s plus SD
time, an estimate: not timed on the board).
- Sources are read sector by sector (`FS_FileInfo` / `FS_ReadSector`): any
  size up to 64 KB per file. `INCLUDE "../lib/ui.inc"` is resolved from the
  including file's folder, like lwasm; if absent, `UI.INC` alone in that
  folder, then at the root (flat cards). 4 levels. Source and output may be
  paths; a bare output name goes to the current folder.
- Size rules are lwasm's object-mode rules, measured: memory operands are always
  extended unless `<`; a label or a forward reference forces the long form
  (16-bit offset, 16-bit PCR, also a PCR to an absolute constant); a known
  constant takes the shortest form; a zero indexed offset gives `,R` except the
  literal text `0` (5-bit). RMB emits zeros. Don't "optimise" any of that.
- Symbols are case-sensitive (lwasm), mnemonics and registers are not. An EQU
  that refers to a later symbol is provisional: a pass 3 (no output) recomputes
  it before pass 2. ORG/RMB refuse forward references.
- Supported: IF/IFNE/IFEQ/IFGT/IFGE/IFLT/IFLE/IFDEF/IFNDEF/ELSE/ENDC/ERROR;
  SECTION and EXPORT are ignored. Not supported: macros, IMPORT, separate
  sections (a `.bss` would be emitted inline), bit instructions, `LDQ #`.
- The output goes to RAM page 2 (32 KB max), then `FS_SaveFile`, `FS_SetLoad`,
  `FS_SetAttributes`: an existing file keeps its page and attributes; a new
  one gets page 1, plus `a` if the source includes `VISION.ASM`.
- `deploy_sd.sh` ships `GLOUTON.ASM` and its includes, so
  `ASM GLOUTON.ASM /BIN/GLOUTON` works on the board (~20 M instructions).

## Version control

Single `master`. Remote `origin` is a bare repo on a FAT32 USB stick (trust
`git remote -v`). The KiCad sources of every board (V2, V3, CPU, CRT,
CRT2, CRT3, power supply, SD-KBD-SON, OSM39_mono) are a SEPARATE repo in
`~/Documents/kicad/OSM09` (its own `.gitignore`: no backups, caches,
locks, freerouting files or gerber folders; the `gerber.zip` actually
ordered is kept), remote `osm09-kicad.bare` on the same stick. Commit there
after a schematic or PCB change. Push fails harmlessly when unplugged; run `git fsck` on the bare
repo after re-plugging. `core.fileMode false` on the bare repo only. Never write
into the old `CLE USB/OSM39V2` copy.

Public mirror: `python3 tools/publie/publie.py` rebuilds
`~/Documents/OSM39-public` (pushed to GitHub, `christophetoularastel-eng`)
from what is COMMITTED here plus `OSM39_mono` from the KiCad repo: drops
what cannot be published (BBC BASIC and asm6809, basic69 = Microsoft,
fonts of unknown origin, vendor `.STEP` models), renames the games
(trademarks: GLOUTON, ENVAHIS, BRIQUES, DONJON39) in paths and text,
patches the Makefiles and `deploy_sd.sh` (each patch must apply), adds
README (`tools/publie/README.public.md`), licences (GPL v3 software,
CERN-OHL-S hardware, CC BY-SA docs) and the schematic PDF/BOM. Then build
and run the verifiers THERE before committing and pushing it.

`.gitignore` lists outputs by name, not extension (fixtures and fonts are `.bin`).
A new extensionless output needs a line there.

## After a `make clean`

`clean` must never touch versioned files. Some `clean` targets miss outputs
(`basic69`: `BASIC`, `basic.hex`) and `deploy_sd.sh` checks existence,
not freshness. **Look at `git status` after a clean build.**

## Known stale text (fix opportunistically, then log in `docs/historique.md`)

- `bios/vectors.asm` comment list: `sys_memcpy_32_bytes`, and `sys video_wait_vsync`.
- `asm/dbg.py`, `decode_trap.py` hardcode BIOS addresses from an older link.
- `test/Makefile` target `indexation` runs a script that does not exist.
- `games/Makefile clean` references an undefined `$(SONDE_OBJ)`.
- `update_includes.py`: six `page_copy_*` symbols, all "not found in map".
- `bios/README.txt`: pre-lwtools commands.
