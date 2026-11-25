#!/usr/bin/env python3
r"""update_includes.py - Generate the two .inc files consumed outside bios/.

Usage:
    update_includes.py <map-file> <vectors-asm> <hardware-out> <sysfunc-out>

Both outputs are derived from `ram.map`, which is linked from `ram.o` ALONE (not
from the full link). That makes `ram.asm` the single source of truth for the
$C000 BSS layout, and keeps the dependency graph acyclic:

    ram.asm -> ram.o -> ram.map -\
                                +-> update_includes.py -+-> hardware.inc
    vectors.asm ----------------/                       \-> sysfunc.inc

Writing these files is IDEMPOTENT: if the content is unchanged the file is not
touched, so its mtime is preserved and make does not rebuild every module that
includes it. Keep that property.

`sysfunc.inc` gives the byte offset of each `sys_*` slot inside
`table_function_ram`, i.e. `address - table_function_ram`. Names and order both
come from the `rmb 2` slots in `ram.asm`.

The generator ENFORCES the invariant that used to be a documentation promise:
the `sys_*` slots in `ram.asm` and the `fdb` handlers in
`vectors.asm:table_function_rom` must be the same length AND positionally
aligned, so adding a service and getting the two files out of step is a build
failure rather than a silent remap. Name equality is checked too, with a short
allowlist of three historical divergences where the BSS slot and the routine
were renamed independently.
"""
import re
import sys
from pathlib import Path

if len(sys.argv) != 5:
    sys.exit("usage: update_includes.py <map-file> <vectors-asm> "
             "<hardware-out> <sysfunc-out>")

map_path = Path(sys.argv[1])
vectors_path = Path(sys.argv[2])
hw_path = Path(sys.argv[3])
sf_path = Path(sys.argv[4])

for p in (map_path, vectors_path):
    if not p.exists():
        sys.exit(f"fichier introuvable: {p}")

# RAM addresses that user programs need. Anything not listed here is invisible
# outside the BIOS. A symbol missing from the map is reported in the output as a
# `; name: not found in map` comment, not treated as fatal.
symbols = [
    "table_function_ram",
    "input_buffer",
    # `NEW_CODE` must be exported for the same reason: basic69 used to read it
    # via a hardcoded `NEWCODE EQU $C043`.
    "NEW_CODE",
    # Octet brut du clavier PS/2 (posé par handler_NMI) et compteur de trames
    # (handler_IRQ) : un jeu lit les touches enfoncées/relâchées lui-même,
    # scan_keyboard ne rendant la main qu'au relâchement (apps/envahis.asm).
    "SCAN_CODE",
    "vsync_tick",
    "MUSIC_PTR",
    "SND_BUF",
    "argc",
    "argv",
    "FormattedName",
    "current_page",
    "page_copy_src_bank",
    "page_copy_dst_bank",
    "page_copy_offset",
    "page_copy_count",
    "page_copy_saved_page",
    "page_copy_tmp",
    "BUF_HEAD",
    # GR_FIN dans le Terminal : l'écran hors de la zone est perdu, le SHELL
    # appelle la routine de redessin d'OSM-VISION (shell/shell.asm).
    "ecran_abime",
    "BUF_TAIL",
    "VRAM_PTR",
    "CUR_PAGE",
    "ASCII_BUF",
    "COLOR_BUF",
    "vram_line_ptr",
    # `char_attribut` must be exported: basic69 (a user program) has only
    # hardware.inc to work from, and used to hardcode $C652, which is only
    # correct for one specific BSS layout.
    "char_attribut",
    "g_find_fileInfo",
    # rapport du dernier TRAP (bios/IT.asm), lu par cmd/MONITEUR
    "trap_frame",
    "trap_info",
    # son coupé (OSM-VISION, touche M), lu par lib/vision.asm dans chaque application
    "son_coupe",
    "serie_brute",
    "serie_tete",
    "serie_queue",
    "serie_buf",
    "kbd_echap",
    "gfx_tampon",
    "kbd_tete",
    "kbd_queue",
    "kbd_apres_f0",
    "e0_received",            # OSM-VISION vide la file comme scan_keyboard
    "kbd_buf",
    "cz_actif",
    "cz_l",
    "cz_h",
    "cz_haut",
    "cz_op",
]

# ------------------------------------------------------- the board (CARTE)
# The file CARTE at the root of the repository says which board the whole
# tree is built for: "v4" (CRT2 video board, char and colour planes 4 KB
# apart) or "mono" (OSM39_mono: VRAM interleaved, char at even addresses,
# colour at the next odd one). Everything that touches the VRAM uses these
# names, so a v4 build stays byte-identical to the code written before mono.
CARTE_FICHIER = Path(__file__).resolve().parent.parent / "CARTE"
CARTE = CARTE_FICHIER.read_text(encoding="utf-8").split()[0].lower()
if CARTE == "v4":
    VRAM_CARTE = [
        (";CARTE v4 : caracteres en $8000-$8FFF, couleurs en $9000-$9FFF (a12", None),
        (";choisit la RAM, U126 de la CRT2). VRAM_CTRL ne garde que la page D0-D2.", None),
        ("CARTE_MONO  equ 0", None),
        ("VRAM_PAS    equ 1", None),
        ("VRAM_LIGNE  equ 80", None),
        ("VRAM_END    equ $9000", None),
        ("VRAM_COL    equ $9000", None),
        ("VRAM_COL_END equ $A000", None),
        ("VRAM_COL_OFS equ $1000", None),
    ]
elif CARTE == "mono":
    VRAM_CARTE = [
        (";CARTE mono : VRAM entrelacee, case c = caractere en $8000+2c, couleur", None),
        (";en $8001+2c (A0 choisit la RAM). Les boucles de cases avancent de", None),
        (";VRAM_PAS ; VRAM_END et VRAM_COL_END bornent ces boucles. VRAM_CTRL :", None),
        (";page D0-D2, D3 = GRAPH (mode graphique : a laisser a 0).", None),
        ("CARTE_MONO  equ 1", None),
        ("VRAM_PAS    equ 2", None),
        ("VRAM_LIGNE  equ 160", None),
        ("VRAM_END    equ $A000", None),
        ("VRAM_COL    equ $8001", None),
        ("VRAM_COL_END equ $A001", None),
        ("VRAM_COL_OFS equ 1", None),
    ]
else:
    sys.exit(f"erreur: {CARTE_FICHIER} dit '{CARTE}' ; attendu v4 ou mono")

# RAM and ROM hardware addresses. These are fixed by the board, not by any
# symbol table, so they are written out literally.
hardware_equ = [
    (";vecteurs d'interruption en RAM : section .ram_vectors, fixee a $DFF0", None),
    (";par l'edition de liens (bios/Makefile) ; rvec_SWI3 en est le premier mot", None),
    ("rvec_SWI3   equ $DFF0", None),
    ("rvec_IRQ    equ $DFF6", None),
    (";pagination", None),
    ("pager_reg       equ $A0C0", None),
    (";PIA", None),
    ("CRA         equ $A042", None),
    ("CRB         equ $A043", None),
    ("PIADRA      equ $A040", None),
    ("DDRA        equ $A040", None),
    ("PIADRB      equ $A041", None),
    ("DDRB        equ $A041", None),
    (";ACIA", None),
    ("CR_reg      equ $A000", None),
    ("SR          equ $A000", None),
    ("TDR         equ $A001", None),
    ("RDR         equ $A001", None),
    ("CR_key      equ $A180", None),
    ("SR_key      equ $A180", None),
    ("TDR_key     equ $A181", None),
    ("RDR_key     equ $A181", None),
    (";SD-KBD-SON : SPI materiel de la carte SD", None),
    ("SD_CTRL     equ $A140", None),
    ("SD_DATA     equ $A148", None),
    (";SD-KBD-SON : AY-3-8910 (ecrire AY_ADR : choix du registre ; lire AY_ADR : sa valeur)", None),
    ("AY_ADR      equ $A150", None),
    ("AY_DATA     equ $A151", None),
    (";TIMER", None),
    ("CR1         equ $A080", None),
    ("CR2         equ $A081", None),
    ("STATUS      equ $A081", None),
    ("CR3         equ $A080", None),
    ("TIMER1      equ $A082", None),
    ("TIMER2      equ $A084", None),
    ("TIMER3      equ $A086", None),
    (";VIDEO", None),
    ("CRTC_RS     equ $A100", None),
    ("CRTC_DATA   equ $A101", None),
    ("VRAM_CTRL   equ $A120", None),
    ("VRAM_BASE   equ $8000", None),
] + VRAM_CARTE + [
    (";Passerelle entre pages (bios/farcall.asm), table de sauts FIXE en EPROM", None),
    ("FAR_CALL    equ $FFE0", None),
    ("FAR_CALLN   equ $FFE3", None),
    ("KERNEL_START    equ $0000", None),
    ("RAM_START   equ     $c000", None),
    ("RAM_TOP     equ     $dFeF", None),
]

# ------------------------------------------------------------------ read map
values = {}
slots = {}
bornes = {}
for line in map_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    m = re.match(r"^Symbol:\s+(\S+)\s+\((\S+)\)\s*=\s+([0-9A-Fa-f]+)", line)
    if not m:
        continue
    name, unit, addr = m.group(1), m.group(2), int(m.group(3), 16)
    if unit != "ram.o":
        continue
    if name in symbols:
        values[name] = addr
    if name in ("table_reserve", "table_function_ram_end"):
        bornes[name] = addr
    if name.startswith("sys_"):
        slots[name] = addr

if "table_function_ram" not in values:
    sys.exit(f"erreur: table_function_ram absent de {map_path}")
base = values["table_function_ram"]

# ------------------------------------------------- read the ROM dispatch table
handlers = []
reserve = []
in_table = False
in_reserve = False
for line in vectors_path.read_text(encoding="utf-8",
                                   errors="ignore").splitlines():
    stripped = line.strip()
    if re.match(r"^table_function_rom:", stripped):
        in_table = True
        continue
    if in_reserve:
        if re.match(r"^table_function_rom_end", stripped):
            break
        m = re.match(r"^fdb\s+(\S+)", stripped)
        if m:
            reserve.append(m.group(1))
    elif in_table:
        if re.match(r"^table_function_end", stripped):
            in_table = False
            in_reserve = True
            continue
        m = re.match(r"^fdb\s+(\S+)", stripped)
        if m:
            handlers.append(m.group(1))

# ------------------------------------------------------------ the invariant
slot_names = [n for n, _ in sorted(slots.items(), key=lambda kv: kv[1])]
rom_names = ["sys_" + h for h in handlers]

if not slot_names:
    sys.exit(f"erreur: aucun symbole sys_* dans {map_path}")
if len(slot_names) != len(rom_names):
    sys.exit(
        "erreur: table de dispatch deschedule - les longueurs different\n"
        f"  ram.asm             : {len(slot_names)} emplacements 'rmb 2'\n"
        f"  table_function_rom : {len(rom_names)} entrees 'fdb'\n"
        "  Rappel: ajouter un service = 1 'rmb 2' dans bios/ram.asm\n"
        "          + 1 'fdb' dans bios/vectors.asm, a la MEME position."
    )

# Le nom `sys_*` n'est PAS derivable mecaniquement du libelle du handler : le
# BSS et la routine ont evolue separement. Ces 3 ecarts sont historiques et
# assumes (le nom `sys_*` est celui qu'appellent tous les appelants, donc c'est
# lui qui fait foi). Toute AUTRE divergence, ou l'apparition de l'une de celles
# ci, doit faire echouer le build.
KNOWN_DIVERGENCES = {
    "sys_pager": "sys_Pager",          # BSS abrégé, routine Pager
    "sys_loadandexec": "sys_LoadandExec",
    "sys_ls": "sys_ls_cmd",            # BSS abrégé, routine ls_cmd
}
bad = []
for i, (slot, rom) in enumerate(zip(slot_names, rom_names)):
    if slot == rom:
        continue
    if KNOWN_DIVERGENCES.get(slot) == rom:
        continue
    bad.append((i, slot, rom))
if bad:
    detail = "\n".join(
        f"  indice {i:>2}: ram.asm={slot}  mais  table_function_rom={rom}"
        for i, slot, rom in bad)
    sys.exit(
        "erreur: table de dispatch deschedule - l'ordre ne correspond pas\n"
        f"{detail}\n"
        "  L'ordre de sys_* dans ram.asm DOIT etre identique a l'ordre des\n"
        "  'fdb' dans table_function_rom (bios/vectors.asm)."
    )

# La table a une taille FIXE : un nouveau service prend un emplacement de la
# réserve, sans décaler la RAM système qui suit (SCAN_CODE, sd_err...). Changer
# TABLE_OCTETS casse tous les programmes déjà compilés : à ne faire qu'en
# connaissance de cause, en redéployant toute la carte SD.
TABLE_OCTETS = 96
if set(bornes) != {"table_reserve", "table_function_ram_end"}:
    sys.exit("erreur: table_reserve / table_function_ram_end absents de ram.map")
total = bornes["table_function_ram_end"] - base
libres = bornes["table_function_ram_end"] - bornes["table_reserve"]
fin_slots = max(slots.values()) + 2
if bornes["table_reserve"] != fin_slots:
    sys.exit("erreur: table_reserve doit suivre immédiatement le dernier sys_*")
if total != TABLE_OCTETS:
    sys.exit(
        f"erreur: table_function_ram fait {total} octets au lieu de {TABLE_OCTETS}\n"
        "  Un service ajouté prend 2 octets à table_reserve (ram.asm) : la RAM\n"
        "  système qui suit ne doit pas bouger.")
if any(h != "Sys_Absent" for h in reserve) or 2 * len(reserve) != libres:
    sys.exit(
        f"erreur: réserve désaccordée : ram.asm {libres // 2} emplacement(s) libre(s),\n"
        f"  vectors.asm {len(reserve)} 'fdb Sys_Absent' après table_function_end.")

# ------------------------------------------------------------ hardware.inc
lines = [
    "; Auto-generated from bios/ram.map by update_includes.py",
    "; Do not edit manually; rebuild the BIOS to refresh these addresses.",
    "",
]
for text, _ in hardware_equ:
    lines.append(text)
lines.append("")
for name in symbols:
    if name in values:
        lines.append(f"{name}:       equ ${values[name]:04X}")
    else:
        lines.append(f"; {name}: not found in map")
lines.append("")

# -------------------------------------------------------------- sysfunc.inc
sf = [
    "; Auto-generated from bios/ram.map by update_includes.py",
    "; Do not edit manually; rebuild the BIOS to refresh these offsets.",
    ";",
    "; Byte offset of each sys_* slot inside table_function_ram. Call as:",
    ";     JSR [table_function_ram+sys_<name>]",
    ";",
    "; Source of truth: the `rmb 2` slots in bios/ram.asm. Count and order are",
    "; checked against table_function_rom (bios/vectors.asm) at build time.",
    "; The right-hand column is the handler that table_function_rom dispatches",
    "; at that offset, kept visible so a misordering shows up in a diff.",
    "",
]
for (name, addr), rom in zip(sorted(slots.items(), key=lambda kv: kv[1]), rom_names):
    label = rom[len("sys_"):]
    if name != rom:
        label = f"{label}  (nom sys_ diverge, assumé)"
    sf.append(f"{name + ':':<32}equ {addr - base:>5}  ; {label}")
sf.append("")


def write_if_changed(path: Path, content: str) -> None:
    # Idempotent write: an unchanged file is left alone so that make does not
    # cascade a rebuild through every module that includes it.
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return
    path.write_text(content, encoding="utf-8")


write_if_changed(hw_path, "\n".join(lines) + "\n")
write_if_changed(sf_path, "\n".join(sf) + "\n")
