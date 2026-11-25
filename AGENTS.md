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

- **Target board: the file `CARTE`** (one word, `v4` or `mono`, versioned).
  **`mono` since 2026-11-18**: OSM39_mono is the machine in service. The V4
  machine (CPU + CRT2 + SD-KBD-SON boards) is ARCHIVED: its code paths stay
  and `echo v4 > CARTE` still builds it (last verified at tag `v4-archive`,
  release v1.2 ships its firmware), but nothing checks it any more.
  `update_includes.py` reads it
  and writes the board's VRAM layout into `hardware.inc`; every program
  depends on `hardware.inc`, so switching rebuilds the tree. `deploy_sd.sh`
  prints the board (and, for `mono`, `PAS_MONO`, the programs not
  converted yet: empty since 2026-11-13). Details in **Video / OSM39_mono**.

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
- `apps/osmcity.asm` (OSM City: drive a car through Annonay seen from
  above; original game, the user's son's idea). Full screen 80 x 30,
  text mode: the car stays on row 15 (column 40; 39-40 heading east or
  west) and the town scrolls by the 6845 start address (`Debut`, cells
  mod 4096; R12/R13 = Debut - 1): a step writes the incoming column (30
  cells) or row (80 cells, one or two `TFM`), the two cells left behind
  and the car, prepared during the frame and written right after the
  frame signal (`Fenetre`/`Appliquer`, no IRQ hook; <= ~1400 estimated
  cycles). Arrows = absolute direction: accelerate, brake on the
  opposite, turn as soon as the side cell is free; slow off the
  roadway; buildings and water stop the car.
  - Map: 512 x 255 cells of ~2.45 x 5.9 m, 4 bits each, the file
    `OSMCITY.MAP` (65 280 bytes: `FS_LoadFile` refuses exactly 64 KB,
    its size is 16 bits) loaded in pages 2-3; the game keeps the 32 rows
    around the car in a ring at `$4000` (`Charge_Rangee`, one `FarRead`
    per north/south step), so the code must end before `$4000`
    (Makefile check).
  - Tiles: each cell's glyph comes from its kind and its 4 neighbours
    (kerbs, roof outlines, banks, bridge rails: `Tuile`, and a fast row
    version in `Prep_Rangee` that decodes 3 map rows first). The glyphs
    are in page 1 of font BANK 1: a 28C256 font chip with `$A120` D4-D5
    on A13-A14 (U525 O4/O5 -> U515 pins 26/1; NOT fitted yet, chip on
    order). The game writes `$10` to `$A120` at start, 0 on exit. The
    32 KB font is `dist/EPROM/font_osm39_28c256.bin` (bank 0 = today's
    font, bank 1 = text + tiles, banks 2-3 = bank 0). With the AT28C64
    still fitted the screen shows bank 0 glyphs (unreadable).
  - The single source is `tools/osmcity/osmcity.py` (the map from
    `tools/osmcity/donnees/annonay.json`, Overpass extract of
    2026-11-21, ODbL: credit "© contributeurs OpenStreetMap"; the tile
    rule `tuile`; the exact model `Jeu`) and `tools/osmcity/glyphes.py`
    (drawings, `--police`, `--planche`). `--inc` writes
    `apps/osmcity_data.inc` (never edit), `--carte` the map (built by
    `apps/Makefile`).
  - Two levels: bridges come only from `bridge=yes` ways (no more road
    over water guessed as a bridge). Kinds `PONT` (deck over water),
    `TABLIER` (over anything else), `SOUS_PONT` (over a road or path: the
    car passes under, hidden), `RAMPE` (a road cell at a bridge end, next
    to the deck). The car has a level `Niv` (0 ground, 1 deck): `Passe`
    (model `passe`) lets it onto a deck only from a deck or a ramp, off a
    deck only onto a ramp; on the ground only `SOUS_PONT` decks are
    crossed. Deck rails face neighbours that are neither deck nor ramp
    (`Garde`). The start is data (`DepartX`/`DepartY`): the verifier's
    second session starts under the Montgolfier bridge and must drive
    both on the deck and under it.
  - Rounded corners: in genres 0 and 3 a cell whose exposed sides are
    N+W, N+E, E+S or S+W, both of one colour other than its own, gets one
    of 4 quarter-ellipse glyphs (`G_COIN`): its colour as foreground (8
    for black), the neighbours' as background (`Coin`, `Note_NC`, tables
    `Coul`, `CoinT`). `TALUS` (grass within 3 x 2 cells of a deck) looks
    like grass but stops the car (no climbing from the street below to a
    ramp across a lawn).
  - 8 directions: two arrows = a diagonal (`VouluT[8 up + 4 right + 2
    down + left]`, opposite arrows cancel). Two advances `Ax`, `Ay` (y x
    107 / 256); on a diagonal each axis gets v x 181 / 256; x step then y
    step (`Passe` each), so one frame may write a column AND a row. On a
    diagonal a blocked side lets the car slide; both, or straight into a
    wall: full stop. Diagonal cars: 2 glyphs each at `G_VOITD` ($90).
    One tile rule for all paths: `Calc_Case` (TS, VN VE VS VO, XB YB);
    `Tuile` reads the 5 kinds with `SorteC`, rows decode 3 map rows,
    columns decode 3 map columns straight from the ring (`Prep_Colonne`).
    The verifier runs a third, scripted session of long diagonals on the
    place de Backnang.
  - On foot: Space (make code `$29`, `KeyEsp`), even while moving (the
    car stops dead), leaves the car parked (`Bascule`: the first free `Sorties` cell, not the car's
    own) and walks (`Marche`: the arrow's direction at once, `VPIED`, no
    inertia; starting or turning sets both advances to `PAS - 1` so the
    first step is immediate; then the common `Pa_Avance`); Space next to a parked car
    (its (x, y) within 1 cell, same level) takes it (`VCoul` = its
    colour). `Garees` (32 x 8 bytes: x, y, direction, colour, level,
    free) starts with 31 cars (`garees_depart`: one right by the start);
    parked cars block (`Occupe` in `Passe`) and are drawn over the tiles:
    `Garee_Case` (in `Tuile`), `Garees_Rangee`, `Garees_Colonne` (one pass
    over the list, no grid). The verifier's 4th session exits, walks,
    takes another car.
  - Traffic (`Population`): 8 cars and 8 walkers in `Mobiles`, right
    after `Garees` in the same 8-byte format (direction 8 = a walker,
    `VoitG` index 16/17), so drawing and collisions handle them. They live
    near the player, in the ring's rows (y - 16 .. y + 15: outside, the
    6309 has no map) and within 52 columns; else they respawn just off
    screen (`Apparait`). One car moves per frame (each every 8 frames,
    vertical every other time), one walker every other frame; none in a
    frame where the player steps (the frame is already full). Choices by
    an 8-bit LFSR (`Alea`, `$B8`), identical in the model. A moved
    entity: the cells it left get `Tuile`, its new cells the glyph on
    the background of the cell's kind (`Attr`; the same rule for every
    vehicle and walker, the player's included), never over the plate.
    `Fait_Proches` lists the parked cars near the player plus all the
    traffic: `Occupe` and the overlays walk only that list.
    `Calc_Case` has a shortcut for a cell whose 4 neighbours are of its
    own kind (rows went from ~8900 to ~6000 instructions).
  - Driving (`Roule`, model `roule`; traffic and police on patrol): a
    draw `RoR` < `VIRAGE` turns into a side street (`Ouverture`: `OUV_V`
    rows or `OUV_H` columns of roadway that way, `Route_Connue` = road
    in the ring rows); else keep right, only in a narrow street (1 to
    `LARGE_V` rows / `LARGE_H` columns of roadway on the right): a
    diagonal step ahead-right, glyph unchanged (never a sideways step);
    else straight on. A car ahead on the roadway: wait `ATT_DOUBLE`
    moves (`Att`, per entity, cleared by any move), then overtake by a
    diagonal step (left, then right), after `ATT_DEMI` a U-turn; end of
    the road: one side, the other, U-turn last. Stuck more than
    `ATT_FIN` moves (`Ro_Coince`): parks if on a `PLACE`, else vanishes
    if off screen. Cars appear facing along the road (`Ouverture_XY`
    from their cell, 4 directions tried). A traffic car stepping on a
    `PLACE` with `RoR` >= `GARER` parks (`Garer`: takes the entry of a
    parked car off screen, its traffic slot respawns). No one-way
    streets (not stored).
  - Sound (`Son`, every frame, all useful AY registers written): A = the
    engine in a car (period 1000 - 5 v, volume 8 + v / 32); B = the horn
    (K held, make code `$42`: 262 / 208 every 8 frames) or the current
    sound effect (noise, volume - 2 per frame; `Effet`: steps, door on
    Space, crash when stopped dead at v >= 48; a new effect replaces the
    current one if it is at least as strong or the current one is over);
    C off. `son_coupe` = `$4D` mutes. On exit: volumes 0, R7 `$3A`. The
    verifier runs with sound on and compares the AY registers each frame.
  - Relief: `tools/osmcity/donnees/altitudes.bin` (IGN altimetry service,
    RGE ALTI, Etalab 2.0: credit "IGN"; 512 x 255 cell centres, dm). A
    grass cell (VIDE, PARC, TALUS) steeper than 70 % with a step over 2 m
    to a neighbour becomes `FALAISE` (hachures, stops the car); roads are
    never changed (hundreds of steep road-road pairs: steep streets,
    walls between parallel streets, DEM noise).
  - `VIDE` (what OSM does not describe: in town, closed gardens and
    yards) stops the car too; public parks (`PARC`) are open, slowly.
    Roads and pedestrian areas have no kerb lines any more (rounded
    corners cut them into stray dashes).
  - Street names: a blue plate (`PLQ_ATTR` `$17`, page-0 text) centred on
    row 29 shows the street of the car's 4 x 4 block (`OSMCITY.RUE`, 8 KB
    grid of name numbers, loaded at `$6000` of page 1; 187 names, CP437,
    in the binary; block 0 keeps the plate). The plate stays put while the
    town scrolls: a south step leaves the old one on row 28 (cells given
    back, `SegB`), a north step pushes it off screen, a side step exposes
    one cell (one `Tuile`); the plate is rewritten by `TFM` (`SegC`).
    Screen writes are segments (`Seg_Pose`/`Prep_Seg`: row, column, count,
    buffer; `SegA` full row, `SegB` partial, `SegC` plate) plus the cell
    list.
  - On exit: start address back to `$FFFF`, font bank 0, rows 25-29
    given back (saved at start; OSM-VISION restores 0-24), Esc release
    awaited.
  - Hide-and-seek (no weapons): a loot (`G_BUTIN`) and a hideout
    (`G_PLANQUE`) drawn at random among `NCANDS` = 64 road cells
    (`Cands`, from `cands()`; hideout at |dx| + 2|dy| >= 120 from the
    loot, 8 tries), both on the map. `Etape`: VOL (blue plate, arrow to
    the loot) -> FUITE on the loot (red plate, arrow to the hideout,
    siren on channel C) -> GAGNE at the hideout or ARRETE when a police
    car touches the player; Space starts a new game (`Nouvelle`). Two
    police cars (`Mobiles` after the traffic, `NPOLICE`), modes PATROUILLE
    / CHASSE / RECHERCHE: they see 24 x 10 cells, recognise the player's
    colour (8 on foot) or anyone within 4 x 2, lose a player hidden under
    a `SOUS_PONT`, search the last seen cell for 120 moves. A chase step
    never reverses unless it is the only way; if no move gets closer, a
    random one (`Alea`). `Bilan` after each move (player step or police
    tick); a police tick that changes the phase redraws the plate at
    once. The police cars start parked at `Poste` (`POSTE`, in front of
    the town hall, rue de l'Hôtel-de-Ville) and stay there until the
    theft; outside the known zone (ring rows, +-52 columns) or off the
    roads they move without the map (`Aveugle`: one step towards the
    target, entering the zone only onto a free cell, else sideways), so
    they always come from the town hall. `Fige`: nothing moves while a game is over (nor on the restart
    frame). On a shared cell the last entity of the list is drawn
    (`Garee_Case` walks the list backwards, like the rows); the player's
    own cells are redrawn by `Case_Ecran` (`Cel_Ecran`). The verifier's
    5th and 6th sessions steal, get arrested, replay, and win.
  - After any change to either side, run `make -C test osmcity`
    (`OSMCITY_PNG=f.png` saves what the binary shows).
- `apps/osm3d.asm` (OSM3D: Annonay in 3D, the user's request after OSM City;
  a separate game because OSM City's page 1 is full). Walking only so far:
  Up/Down held walk; each Left/Right make code (the press, then every
  keyboard repeat) turns `ROTATION` = 16/1024 (`Tourne` = steps pending,
  at most `TOURNE_MAX`); Esc. Turning while the key is HELD (own repeat
  in the IRQ) was tried on 2026-11-22: on the board a short tap kept
  turning (release not seen, cause unknown), so it was reverted. Full screen 80 x 30: the view (64 x 18 cells of 2 x 3
  mosaics, rows 0-17), the mini-map in a CP437 frame (columns 64-79, rows
  0-17, 14 x 16 cells, one point = 2 map columns x 1 row, a yellow CP437
  arrow at the centre), the street plate (row 19, centred under the view),
  help (row 20). Mini-map: buildings red, sidewalks white, grass green.
  - Its own map `OSM3D.MAP` (pages 2-3, 32-row ring at `$4000`): OSM
    City's, made for 3D by `osm3d.carte()` = `osmcity.carte(...)` with
    options whose defaults leave OSM City's map unchanged: `CORDEAU`
    (ways straightened by Douglas-Peucker at 8 m between junctions, kept
    in place: `simplifie()`), `ELARGI`/`TROTTOIR` per highway value (main
    roads 1.5 times wider with a 2.5 m sidewalk taken from `BATI`),
    `FAIBLES` (minor streets yield to buildings, only their axis stays
    road: old-town lanes keep their real width), `ALLEES` (parking aisles
    drawn as parking), `PIETONNES` (pedestrian areas as `PIETON`, not
    `PLACE`), `RACCORDS`; then `lisse()` (no one-cell building bump or
    notch), `ponts()`, `marquages()` (kind `BORDURE` = 13: sidewalk
    touching the roadway, parking touching the driving lanes), `culees()`,
    `finir()` (PARC and TALUS merged into VIDE: same green, walkable;
    their numbers 5 and 11 become `PONT_ARC`/`SOUS_ARC`). Ground: roadway
    black, sidewalk and kerb white, parking grey (15), water blue, sky
    CYAN (3). Unit = one map column (2.455 m), a row = `RY` / 256 = 2.4
    units. One ray per column, DDA; each cell crossed paints its ground
    colour (`SolB`), the first `BATI` is a 16 m wall (`Facades` by block,
    all attenuated: ochre, brick, ochre, grey render; a face crossed in y
    with x even gets WINDOWS: one subrow in 3 black, `Fenetres`); rays stop
    at `DMAX` or out of the ring rows.
  - Bridges (`ponts()`, after the user's drawing of 2026-11-25): each
    `bridge=yes` way is redrawn along its axis at the drawn width of the
    road it carries (the OSM City footprint is removed, the ground under
    recovered). Deck cells: `PONT` over water, `SOUS_PONT` only where a
    way that CROSSES the bridge axis passes under (Simone Veil under the
    Montgolfier bridge; the Valgelas bridge only spans the Deûme),
    `TABLIER` elsewhere = a solid embankment; `RAMPE` on the first 3 axis
    cells of the approach ways. `ARCHE_D` = each passage cell's place in
    the span (0 at the edge, 1 on the axis of the way under); under
    `ARC_BORD` it becomes `SOUS_ARC`/`PONT_ARC` (the foot of the arch).
    `culees()`: `CULEE` (14) = passage cell or lower cell touching a ramp;
    `MURET` (15) = upper approach cells touching the lower street (a 1.2 m
    wall: no more ground link between the two).
  - Levels: `Niv` (0 ground, 1 deck), `Passe` = model `osm3d.passe`
    (grass is walkable, unlike `osmcity.passe`; bati, water, cliff,
    muret stop; onto a deck kind (`TABLIERS`) only from a deck or a ramp,
    off it only onto a ramp; on the ground only `SOUS_PONT`/`SOUS_ARC`
    are crossed); the level changes when the position's cell changes.
    On the ground (`MasqD`, `MasqM`), `SolB` flags: `DESSOUS` ($40, under a
    deck), `ARC_F` ($80, foot of the arch), `MUR_P` ($20, culée or
    embankment), `MURET_F` ($10); painted colour `& 15`. Under a deck
    from `DIn` to leaving (or a wall, or the end: `NIDX - 1`): white
    parapet (`Parapet`: `pg = pt + pt x Q_GARDE / 256`, `pt` = `PTop2`
    at 7 m) then stone down to `PBot2` at 5 m (x `Q_ARC` / 256 = 3 m when
    the last cell is an arch foot), over sky only. A culée or embankment:
    parapet, stone from `PTop2` to the foot, the ray goes on above
    (`Mur_Pont`); a muret: stone from `Bas x Q_MUR / 256` below the horizon
    (`Muret`). No new tables: heights come from the existing ones by an
    8-bit `MUL`, exactly as in the model. On the deck decks are ground.
    Mini-map: decks grey, muret white (no railing line: it would need the
    neighbours of each point). Two colours per cell (rule in `osm3d.py`'s
    header; `Cel_Mini` uses it too since attenuated grey is on the map).
  - Street names: `OSM3D.RUE` at `$6000` (64 x 128 block grid as runs +
    the names), generated. The code ends before `TAMPONS` (`$2600`,
    Makefile check); the buffers fill `$2600-$3FDF`.
  - Every VRAM access (view rows, mini-map rows, text rows, saving and
    giving back rows 25-29) goes through a job queue (`Jobs`, `Ajoute`)
    emptied by `Irq_3D` (hooked in `rvec_IRQ`) at the start of the frame,
    within `BUDGET` cost units per frame (bytes + `COUT_COPIE` per job).
    `Want`/`Pret` swap when the queue is empty; `MiniBuf`/`TxtBuf` change
    only then. `Irq_3D` also reads the keyboard (`Lire_Clavier`) every
    frame: read only between images, typematic repeats filled the NMI's
    16-byte queue during a long image and the release was lost (the
    board kept turning). Ring rows are loaded right after a frame (`FarRead` masks
    IRQs).
  - The renderer paints ground only when the colour changes (same result
    as the model, which paints every cell); `Mark` lets `Composer` write
    runs of one-colour cells. Measured (emulator, 7000 instructions per
    frame): 4-12 frames per image turning, 10.7 on average (windows and
    bridges mark more cells mixed; 6.8 before 2026-11-25); the copy alone
    needs ~5 when
    the whole view changes. The mini-map rebuild (on a new cell or quarter
    turn) costs ~22 000 instructions.
  - The single source is `tools/osm3d/osm3d.py` (tables, `ecran()` = the
    exact screen, `--inc` -> `apps/osm3d_data.inc`, `--carte`, `--rues`,
    `--png`).
    After any change to either side, run `make -C test osm3d`.
  - `tools/osm3d/dessin.py FILE.txt [--plein] [--osm3d X Y ANGLE]`: a Tk
    paint program at the view's resolution (128 x 54 points, cells of 2 x
    3, 16 colours, attenuated ones foreground only; cells the machine
    cannot show are outlined in red); the user draws what they want, the
    `.txt` (one hex digit per point) is read back. Drawings and the
    user's Street View captures live in `tools/osm3d/essais/` (NOT
    versioned: the captures are Google's).
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
- `zmachine/` (ZMACHINE: Z-machine interpreter, versions 3/4/5/7/8, Infocom
  and Inform games, stories up to 256 KB). OSMVISION application in
  `/BIN` (attribute a, page 1); Enter on a `.Z3`/`.Z5`/`.Z8` runs `ZMACHINE
  NAME` (`ExtTable` accepts two-letter extensions). Full screen 80 x 30.
  - Version 3 (Zork I-III, released under MIT by Microsoft: `zork1.z3`
    from `historicalsource/zork1/COMPILED`): `V3`/`Vieux`/`Decal`/`Base`
    set at load; row 0 is the interpreter's status line (`Etat`, built
    through `Sortie` with `VersEtat`), the windows start at `Base`.
  - The single source is `tools/zmachine/zmachine.py` (decoder, objects,
    text, dictionary, the exact screen grid, Quetzal); `--inc` writes
    `zmachine/zmachine_data.inc` (never edit). Games and test suites are
    NOT in the repo: `~/Documents/zmachine` (or `$ZMACHINE_JEUX`).
  - Memory: story block b (256 bytes) at linear (b+1)*256 of pages 2-3
    (blocks 0-254), beyond from the card; a 32-slot cache in page 1
    (`$6000-$7FFF`, slots 0-2 pinned for the globals), write-back via
    `FarWrite`. Y = Z PC pointer into its slot, U = Z stack. The code
    must end before `ZONE` (`$3800`, Makefile check): ~240 bytes left;
    big tables already live outside the code (`TABLES_CAR` `$6000`,
    `AlphaT` `$5B20`), so the cache has 30 slots (`$6200-$7FFF`).
  - Screen: shadow copy in page 1, dirty rows copied by `Irq_Z` (hooked in
    `rvec_IRQ`, 3 rows per frame); rows 25-29 of OSMVISION saved and given
    back by the IRQ; hardware cursor through `VRAM_PTR`. A row is marked
    dirty AFTER it is written (marked before, the IRQ could copy it half
    done and never again).
  - No undo (`@save_undo` = -1). Saves are Quetzal, written in one
    `FS_SaveFile` from page 2 (header put just before the dynamic memory,
    Stks after it, the story bytes it covered re-read afterwards); name
    asked as `Fichier : `, `.SAV` added. frotz reads them.
  - Speed (emulator): 130-190 6309 instructions per Z instruction; slow on
    big Inform games (Zork_LXIX ~30 000 Z instructions per turn).
  - After any change to either side, run `make -C test zmachine`
    (`zmachine-tout`: also praxix and three more games, ~10 min).
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
  - OSMVISION calls the SHELL with U = `Term_Redessine` (desktop, then the
    Terminal window and its zone, cleared). After an external command the
    SHELL calls it if `ecran_abime` (BIOS RAM) is set: `GR_FIN` sets it
    when it closes the graphic mode inside a zone (the text screen is
    lost; it clears outside the zone to `$08`).
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
  - Two binaries: `BBCBASIC` (inline 6309 assembler, from `$2900`: 8 KB
    of programs) and `BBCPLUS` (`NOASM=1`, from `$3200`: 10 KB);
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
    `verifie_bbcbasic.py` records every `sys_Graphe` call in MODE 0 and
    replays it in `graphe.py` (page 3 = the model), plus the expected calls.
    The verifier's emulator lacks NEGD/ASLD (DIVD/DIVQ were added for
    CALC on 2026-10-27): the code avoids them (scaling = high word of `MULD`).
  - `MODE 0`/1/2/4/5 = the BIOS graphic mode (`sys_Graphe`, 640 x 400):
    `Om_Hr`; px = x/2, py = 399 - hi(y x 25600); lines, points, rects,
    circles (`PLOT 144-159`) are single calls; filled triangles (both
    modes) go row by row (`Om_Tri`, two Bresenham walkers, one span per
    row: XOR exact); text by `GR_CAR` on the 80 x 25 grid (wraps to the
    top, clearing rows), XOR cursor in `OSRDCH`. The image is in page 3:
    channel 2 refused while `Om_Hr`, `MODE 0` refused while it is open.
    `gfx_tampon` belongs to the BIOS then: the mosaic queue and its
    inverse table are skipped (`Om_GfxInit` rebuilds them after `MODE 7`).
    `GR_COULEUR` waits for the IRQ to finish the previous one: text only
    colours its cell after a `COLOUR`. `MODE 3`/6/7 and `*BYE` call `GR_FIN`.
  - SOUND (`osm39_son.asm`): notes queued in `SND_BUF` for the BIOS
    sequencer (`snd_play` plays a buffer >= `$C000` without copying);
    6840: 2 square voices, channels play one after another. `son_coupe`
    = `$4D` silences it (the verifier's `lance(..., son=0)` enables it).
  - Not yet: OSGBPB, ENVELOPE, simultaneous channels, VDU 24, GCOL
    colours and scrolling in MODE 0, TIME$.
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

- Slot 0 is `sys_FS_RenameFile`. The non-blocking key read is `sys_kbd_poll`; the console zone is `sys_Console_Zone`; the
  graphic mode is `sys_Graphe` (last used slot; 1 reserved slot left).
- There is exactly one `sysfunc.inc`: `bios/sysfunc.inc`. Never add a local copy.
- `lib/bioslib.asm` thunks: `bsc_<service>`, one `jmp [...]` each. Not every
  service has one (`video_wait_vsync`, `snd_play`, `snd_stop`, `Far_Call*` do not), and
  `bsc_FS_RenameFil` is truncated — grep `bsc_`, not the service name.
- A feature only the boot path needs (splash, boot jingle) is a direct call, not
  a dispatch slot. Add a `sys_*` slot only when a user program must reach it.
- **The contract of every slot** (inputs, outputs, registers destroyed) is
  `test/contrat_services.py`; `docs/services.md` is generated from it
  (`python3 test/verifie_contrat.py --doc`, never edit). A new or changed
  service updates that table, with a scenario: `make -C test contrat` calls
  every slot through the table with sentinel registers and fails on a
  register changed outside the contract, an unbalanced stack, DP, the
  caller's page not given back, or a stale `docs/services.md`. Most file
  services destroy W (only `FS_ReadSector` keeps it), several destroy U.

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
- Reference encodings: 5-bit indexed postbyte = register in bits 6-5 (X `$00`,
  Y `$20`, U `$40`, S `$60`) + the offset in bits 4-0 (`1,S` = `$61`, `0,S` =
  `$60`); `LDY` indexed is `10 AE`, `LDY` extended `10 BE` (lwasm is right). `TFR` postbyte = src<<4 | dst (D0 X1 Y2 U3). `addr u,d` = `10 30 30`.

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
  `bios/osm39.map` (`make -C bios` prints it, and BIOS2's size). Never compute
  it by hand.
- **The BIOS is in two parts** (since 2026-11-13). The EPROM keeps what
  boots and repairs (SD read, file lookup and load, keyboard, screen,
  IRQ/NMI/TRAP, `FarRead`/`FarWrite`, SECOURS). `BIOS2` (`bios/ext.asm`,
  section `.ext`, linked in the same `lwlink` run at `EXT_BASE` = `$CE80`,
  up to `EXT_FIN` = `$DA00`) holds `FS_SaveFile`, `FS_DeleteFile` and the
  graphic mode (`bios/graphe.asm`). Everything else it used to hold
  (rename, attributes, `SetLoad`, `MkDir`, `ListRoot`, `Fs_WriteBlk`,
  `SD_WriteBlock`, the Terminal console, the sound sequencer) came back
  to the EPROM on 2026-11-21 to make room; their `X_` names and `ExtV`
  slots stay, with `Ext_Def` pointing at them from reset. When moving a
  block between sections, check what it falls through into: `X_Audio`
  landed between `UPDATE_CURSOR` and `AUDIO_UPDATE` (now a `BRA`).
  - `bios2.py` extracts `bios/BIOS2` from the S-record and writes its
    length and sum into the EPROM image (`ExtLong`, `ExtSomme`).
    `deploy_sd.sh` ships it as `/BIN/BIOS2`: an EPROM and its BIOS2 go
    together (another BIOS2 is refused by the sum).
  - At every boot (cold or after a TRAP) `main` loads it right after the
    card (`Ext_Charge`), before the jingle. Without it the machine boots;
    `FS_SaveFile`, `FS_DeleteFile` and `sys_Graphe` answer C=1.
  - The EPROM reaches BIOS2 only through 4-byte stubs keeping the old
    names (`FS_SaveFile: jmp [ExtV+EXTV_SAVE]`); `ExtV` (BSS, offsets in
    `bios/ext.inc`) gets defaults from `Ext_Defauts` at reset (`Sys_Absent`,
    `Ext_Rien`, `UPDATE_CURSOR` for the Terminal IRQ) and the real
    routines (`X_...`) from `Ext_Entree`. `verifie_ext.py` (run by the
    Makefile) refuses any other EPROM -> BIOS2 reference: the linker
    resolves them silently, and they would jump into nothing without BIOS2.
  - Moving more code: wrap it in `section .ext`, rename its entry `X_name`,
    put a stub and a new `EXTV_*` slot (keep `Ext_Def`/`Ext_Table` in the
    same order, `EXTV_N` and `ExtV`'s size in step). Short branches across
    sections do not assemble: use `JSR`/`JMP`.
  - Measured: the stack never went below `$DDEB` in any verifier (~520
    bytes from `$DFEF`), so `$DA00` leaves ~1 KB of margin. The system
    heap shrank to 256 bytes (only the SHELL uses it).
  - Verifiers install the whole BIOS through `verifie_fs.installe_bios(m)`
    (service table, `ExtV` defaults, BIOS2 at the start of `.ext`, its
    `Ext_Table`); `Machine` does it when created. System-RAM scratch areas
    in verifiers live at `$DB00-$DDFF` (below their `$DF00` stack).

## Verifiers (`test/*.py`) — run them, don't reason instead

`make -C test tout` runs them all (`test/tout.py`: the recipes are read from
`test/Makefile`, builds once in order, then the scripts in parallel; ~5 min
on 4 cores; logs in `test/tout/`; `tout-long` adds `zmachine-tout` and
`asm-tout`). It checks the board in `CARTE` only.

| script | proves | in `make -C test`? |
|---|---|---|
| `verifie_rendu.py` | `splash_draw` writes exactly what the table says, by replaying emitted bytes | yes (stages 2-5) |
| `verifie_remplissage.py` | fill routines stay in `$8000-$8FFF`, return, cover 4096 per pass, write one value | yes |
| `verifie_constantes.py` | no `equ`/`fcb`/`fdb`/`rmb` hits the space or `<<` trap | yes, repo-wide |
| `verifie_negatifs.py` | the three above fail on 18 injected bugs, each with a distinct diagnostic | `make -C test negatifs` |
| `verifie_fs.py` | the real BIOS, with 4 emulated RAM pages and an egofs SD image, loads and saves across pages 2→3, refuses page 4, restores the caller's page, never overlaps files; the spinner drawn only by a simulated VSYNC IRQ (`Spin_IRQ`), screen intact after, none with IRQ masked | `make -C test fs` |
| `verifie_asm.py` | the real `asm/ASM` on the real BIOS, sources and INCLUDEs on an OSMFS card: every binary byte-identical to lwasm (6309 test, `asm/test/*.asm`, MIRE, GLOUTON; `tout`: all apps and BRIQUES), entry page/address/attributes, error names file and line | `make -C test asm` (`asm-tout`: ~2 min) |
| `verifie_demarrage.py` | the real BIOS from its reset vector: automatic boot, SECOURS (key, serial, `$AA` ignored), LOAD/RUN/BOOT, card without OSMVISION, TRAP report and warm restart, Ctrl+A; BIOS2 loaded and installed, missing (boot still works, services absent), from another BIOS (refused by its sum), damaged by a program then reloaded at the warm restart; `cmd/MONITEUR` on that report (R, E, M, G) | `make -C test demarrage` |
| `verifie_bureau.py` | the real OSMVISION on the real BIOS with scripted keys: copy/paste across folders (content, page, address, attributes), Ctrl+N, cut/paste, rename to a name that exists only at the root, Space-menu letters, paste over an existing name refused, sound icon (barred / with waves after M), `?` shortcut panel (text, file window untouched, second `?` gives back the exact screen, still there after the Space menu), accents typed in Exécuter drawn in CP437 and refused in Renommer, the date and time in the status bar with `verifie_horloge`'s PIA + MC146818 model (none without the card, a minute rollover, a non-BCD digit as `-`, nothing written to the chip), no AY chip (empty bus: no pointer, keyboard still works; R1 given back with the chip), list scrolled by keyboard with every VRAM write at most 1650 estimated cycles after the frame signal (4 per instruction, 6 + 3 per `TFM` byte; the old cell-by-cell list gave ~6200), the same entering a folder and leaving it (old: ~6800), the list window's shadow row intact, CALC and EDIT moved by arrows (program writes only; old: 4380 / 2716) | `make -C test bureau` |
| `verifie_dossiers.py` | the real BIOS's folders: flat card unchanged, MkDir/ChDir/paths/`..`, two formatted buffers, list filtered by folder, root fallback for reads only, non-empty folder kept, move and cycle refusal; `CD`/`MKDIR`/`PWD`/`RM` binaries; OSMVISION's `Load_Directory`/`Draw_FileList` | `make -C test dossiers` |
| `verifie_farcall.py` | the real BIOS's `FAR_CALL`/`FAR_CALLN`, at `$FFE0` and through `sys_Far_Call*`: callee in its page, registers and carry both ways, caller's page back, nesting, page 4 refused, every reserved slot returns C=1 | `make -C test farcall` |
| `verifie_bbcbasic.py` | the real `bbcbasic/BBCBASIC` launched by the real OSMVISION on the real BIOS: arithmetic, FOR/PROC, RUN/LIST, SAVE+LOAD on OSMFS, SAVE twice = one entry, `*CAT`, an error and recovery, `*EXEC` of an LF text, BBCPLUS: free space, `*LOAD` of a lwasm routine + USR, `*SAVE` round trip, no `[`, graphics read back from VRAM (diagonal, filled triangle and colour, POINT, rectangle + GCOL 3, VDU 29 + relative PLOT), SOUND queue in `SND_BUF` (durations, flush, pitches), OPENOUT/PRINT#/BPUT#, OPENIN/INPUT#/BGET#/EOF#/EXT#, OPENUP/PTR#=, Escape from an endless loop (NMI flag), `*BYE` | `make -C test bbcbasic` |
| `verifie_terminal.py` | the real BIOS console in a zone: real `PrintChar`, real VSYNC IRQ frame by frame; VRAM = a model (wrap, zone-only scroll, BS, `$0C`, ignored codes), nothing written outside, cursor, IRQ length; then full screen: `$0C`, 35 lines, hardware scroll (R12/R13 in cells) and cursor (R14/R15) | `make -C test terminal` |
| `verifie_banc_mono.py` | bench stage 9 (`stage9_mono`) replayed alone: only VRAM, `$A120` and the 6845 written, the 4096 interleaved cells equal a separate model, page 0 / GRAPH 0, start `$FFFF`, cursor hidden, IRQ+FIRQ masked | `make -C test STAGE=stage9_mono` |
| `verifie_minitel.py` | the real `apps/MINITEL` `Term_Octet` gives exactly `videotex.py`'s `Terminal`: logical screen and bytes sent back (MiniPavi capture, modem test page, random streams; PCE: the real phone capture, its 75 CRCs, blocks with a damaged block or a lost byte and the NACK/SYN recovery, NUL/DLE transparency, STATUS, STOP); then the whole app with a simulated modem (parity in its answers) and keyboard, and a MiniPavi-like server (START until answered, ENQROM, PCE with one damaged block): `ATE0&D0B2M1S91=6DT0972101721,,,,,` for 3615, window = `cellules40`, Ctrl+F = `cellules80`, desktop back around the window, Minitel keys with even parity, ACIA at `$95`, `+++`/`ATH` with guard silences, NO CARRIER, silent modem, exit restores rows 25-29 and `serie_brute` | `make -C test minitel` |
| `verifie_donjon39.py` | the real `apps/DONJON39` with the VSYNC IRQ taken every frame (its `Irq_Donjon`, then the real BIOS handler) and raw PS/2 bytes: at rest, the VRAM view (glyphs and attributes) equals the model for the position/angle/map in memory (10 places, minimap included), every VRAM write inside the IRQ, early (<= 512 bytes per frame), walls not crossed, Esc returns with the key queue empty and `rvec_IRQ` restored; with a tricky `DONJON39.TXT` on the card: map and start = `texte_carte()`, Space opens the door ahead, it closes by itself, Tab toggles the minimap | `make -C test donjon39` |
| `verifie_osmcity.py` | the real `apps/OSMCITY` (map `OSMCITY.MAP` on the emulated card) with the VSYNC IRQ every frame and raw PS/2 arrows (random holds, fixed seed, ~3300 frames): at every `Pas` the state (position, direction, speed, accumulated advance, start address) = `osmcity.py`'s `Jeu` fed the same arrows; every 10 frames the 80 x 30 screen read through the 6845 start address = `Jeu.ecran()`; the start address wraps past 4096 cells; VRAM writes <= 1900 estimated cycles after the IRQ entry; Esc: RTS, start `$3FFF`, font bank 1 then 0, rows 25-29 given back, key queue empty | `make -C test osmcity` |
| `verifie_osm3d.py` | the real `apps/OSM3D` (`OSM3D.MAP`, `OSM3D.RUE` on the emulated card) with the VSYNC IRQ every frame and raw PS/2 arrows: at 7 stops (walk, turn, walk into a wall, U-turn) and 6 by the Valgelas bridge (under it on the ground, onto it by its ramp) the 30 rows of the screen = `osm3d.py`'s `ecran()` for the position and angle in memory (view, mini-map and frame, plate, help); every VRAM access inside the IRQ, <= 1900 estimated cycles after its entry, <= 546 bytes per frame; no walking into buildings; level and cell always agree (never on a deck at level 0 except `SOUS_PONT`, level 1 only on a deck); one Left/Right press = one 16/1024 step, held = one step per keyboard repeat (`appuis()`), Up held + Right tapped (the keyboard then repeats only Right) keeps walking, an arrow held with 30/s repeats then released stops, no keyboard byte lost by the NMI (a full queue drops bytes, as on the board); Esc: RTS, rows 25-29 given back, `rvec_IRQ` restored, key queue empty; frames per image measured | `make -C test osm3d` |
| `verifie_sdtest.py` | the real `cmd/SDTEST` against an SPI-level SDHC card model on the SD-KBD-SON registers: 80 clocks /CS high, CMD0/CMD8 CRCs, ACMD41 with HCS, OCR, CID, CSD capacity, sector 0, 200 compared reads (missing tokens counted), write + read-back + restore at LBA `$00100000` on O, nothing written on N, no card; spacing between transfers as a lower bound in distinct bus accesses (>= 150 slow, >= 9 fast; 30 slow turns fail) | `make -C test sdtest` |
| `verifie_tele.py` | the real `cmd/TELE` driven by the real `tools/tele/tele.py` over a simulated line (NMI ring in, TDR out): ping, R/W in page 1 (direct), page 2 (FarRead/FarWrite, page restored) and system RAM, call with registers and carry, a BIOS service through the table, bad sum / unknown command / bad length refused, Q leaves raw mode and returns; `depose.py` creates then replaces a file on the emulated card (one entry, content, page, address, attributes read back by `egofs_core`), missing folder refused | `make -C test tele` |
| `verifie_aytest.py` | the real `cmd/AYTEST` against a simulated AY: 28/28 read-backs on a sound chip, 26/28 with the two R9 faults shown when R9 reads 0; each listening step's registers and length (A, B, C at period 262, chord, noise, envelope), silence between steps and at the end, ports never outputs; the BIOS sequencer (`snd_play` + the IRQ's `AUDIO_UPDATE`) drives A and C frame by frame for the boot jingle and a score copied from page 1, then silence | `make -C test aytest` |
| `verifie_ayjoue.py` | the real `cmd/AYJOUE` (`lib/ay_joue.asm`) with the VSYNC IRQ taken every frame and a simulated AY: register state frame by frame = `tools/ay/ay.py`'s model (a test song using the whole format, then KOROBEINIKI until Esc), ends by itself, `rvec_IRQ` restored, silence, frame writes inside the IRQ, `son_coupe` zeroes volumes, no argument / missing file / not a song refused | `make -C test ayjoue` |
| `verifie_clavier.py` | the real BIOS with the keyboard 6850 simulated: Caps Lock toggles `kbd_verr`, case of a-z and é è à ç ù flipped, Shift+letter lowercase, digit row/punctuation/Ctrl/AltGr unchanged; the real `handler_IRQ` sends `$ED` then the LED byte two frames later (TDR, RTS low >= 100 instructions, RTS high), `kbd_muet` counted down, CR `$DC` at IRQ exit; the real `handler_NMI` drops the echo while muted and queues a key afterwards; dead keys `^`/`¨` (vowels, capitals, Caps Lock, Space, another key, arrow, AltGr, AltGr+ç not dead, kept across a `scan_keyboard` entry) | `make -C test clavier` |
| `verifie_horloge.py` | the real `cmd/HORLOGE` (`lib/horloge.asm`) against a pin-level 68B21 and MC146818: no card, VRT, clock not set, setting (BCD registers, SET during the writes, A = `$20`, B = `$02`), weekday of 48 dates vs Python, refused dates/times write nothing, bus rules (Motorola mode, AS/R/W only with DS low, no AD conflict), a read at any phase of the 23:59:59 -> 2027 update is never mixed, PIA left idle; the real BIOS `main` and `Hor_Init` on a freshly reset PIA write nothing to the chip (DS and R/W never change together) | `make -C test horloge` |
| `verifie_zmachine.py` | the real `zmachine/ZMACHINE` on the real BIOS, games on an emulated card, VSYNC IRQ every frame, `sys_kbd_poll` fed with script lines: every character sent to the screen and the whole 80 x 30 shadow screen at each input = `tools/zmachine/zmachine.py`; VRAM catches up, writes only in the IRQ (or the BIOS spinner), <= 3 rows per frame; rows 25-29 and `rvec_IRQ` given back; a save on the card = the model's Quetzal file byte for byte, and restoring it gives the same screen (czech, dreamlands, zsnake with timeouts, Zork I v3 + its save, zork_285; `tout`: praxix, aventure, lieuxcommuns, Zork_LXIX) | `make -C test zmachine` |
| `verifie_contrat.py` | every slot of `table_function_ram`, called through the table on the real BIOS (EPROM + BIOS2, emulated card, SD driver clobbering like the real one) with sentinel registers, success and failure paths: changed registers within `test/contrat_services.py`, stack, DP, page, carry, some outputs; two injected faults must be seen; `docs/services.md` up to date | `make -C test contrat` |
| `verifie_graphe.py` | the real BIOS graphic mode (`sys_Graphe`) with 8 paged VRAM pages, the VSYNC IRQ every frame and a caller whose stack is in its page 1: after each of 89 calls (points, lines of every slope, clipped, XOR; rectangles; circles/discs incl. r = 0, clipped, XOR; characters; GR_LIT; random) page 3 = `tools/graphe/graphe.py`; registers, stack and page given back; after GR_ATTEND the image read back from VRAM and the cell colours = the model, rows 26-29 colours `$08`; VRAM written only in the IRQ, <= 1900 estimated cycles after its entry; console silent; IRQ masked caller; refusals; GR_FIN gives the text screen back | `make -C test graphe` |
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
- One source file per stage. `test/TEST` is
  shared by all stages: check the printed `ETAPE =` line and the byte count.
- Stages 1-8 are V4 only: `common.inc` refuses to assemble when `CARTE` is
  `mono` (their colour-plane loops would run into `$A000`).
  `stage9_mono` is the first-light test of the OSM39_mono board (interleaved
  VRAM written explicitly, any EPROM): title, X red / O green alignment row,
  8 x 8 colour grid, font page 1, all 256 page-0 glyphs, ruler, row 29.
  It is checked by `verifie_banc_mono.py` instead of `verifie_remplissage.py`.
- `ATT_TOURS` 600 ≈ 2 s (cycle count). Frame = 16 ms. `$A120` is write-only, so
  `attente` cannot be rewritten against a frame counter.

## Video

- **OSM39_mono (`CARTE` = `mono`)**: same I/O map, attribute byte, font
  EEPROM layout (A0-A3 row, A4-A11 code, A12 page) and 6845 setup as V4, but
  the VRAM is **interleaved**: cell c = character at `$8000+2c`, colour at
  `$8001+2c` (CPU A0 picks the RAM). `$A120` D3 = GRAPH (keep 0).
  - `hardware.inc` constants: `CARTE_MONO` (0/1), `VRAM_PAS` (bytes per
    cell, 1/2), `VRAM_LIGNE` (bytes per row, 80/160), `VRAM_COL_OFS`
    (`$1000`/1), `VRAM_END`, `VRAM_COL`, `VRAM_COL_END` (bounds of
    cell loops stepping `VRAM_PAS`: never `VRAM_END-VRAM_BASE` bytes from
    `VRAM_COL`, that overruns into `$A000` on mono).
  - The 6845 still counts cells (start address, cursor, `SCREEN_START_OFFSET`):
    CPU byte offsets are halved before going to R12-R15.
  - Code differing per board sits in `IFNE CARTE_MONO / ELSE / ENDC`
    (lwasm and the board's ASM both handle an `equ` defined before the IF).
    The `v4` branch of each IF must still assemble (archive); it is no
    longer verified nor compared byte for byte (that rule held while both
    boards were in service, until 2026-11-18).
  - Converted: everything. BIOS (console, zone, spinner, clear),
    `lib/vram.asm`, `lib/vision.asm` (mono writes cells as char:attr `STD`
    pairs, one pass, budget `MONO_CASE`), OSM-VISION and every app that
    only draws through `vis_*` (EDIT, CALC, SON, PAROLE, MIRE...); the
    direct writers since 2026-11-13: PONT/PONT2, ENVAHIS, GLOUTON, BRIQUES
    (`lib/rowaddr.inc`), MINITEL, DONJON39 (its image buffers are
    interleaved too in mono: `CEL`, `RANG_O`, one `TFM` per row), BBC
    BASIC (graphics cell address, `TAB`, `POS`/`VPOS`), ZMACHINE. Proven
    in mono by `donjon39`, `minitel`, `bbcbasic`, `zmachine`, `asm-tout`;
    ENVAHIS, GLOUTON, BRIQUES, PONT have no screen verifier (assembly only).
  - In a v4 build, keep forward references where the old code had them:
    `LEAX VUE_L,X` (VUE_L defined later) is a 16-bit offset, a known
    constant gives the 8-bit form and breaks byte identity (DONJON39's
    `RANG_O equ VUE_L`).
  - Verifiers read the screen through `test/carte.py` (`adr`, `adr_coul`,
    `lit`, `pose`), which parses `hardware.inc`: they follow `CARTE`
    (mono now).
  - **The board works** (first power-up 2026-11-15, 450 mA) with two
    modifications, wired on the board and drawn in the KiCad schematic
    (commit `483890c`); the PCB is NOT updated yet:
    1. `/8000-9FFF` qualified by E: U103 (74HC32, gate 9/10 -> 8) =
       U106 pin 4 OR `~E` (U101 pin 10), to U501 1-2 and U517 2-4-9.
       U106 (74LS139) is enabled by A15 through the U101 inverter while
       A14/A13 come direct: back from an A15 = 1 cycle (the 6309's `$FFFF`
       dead cycles) to `$0000-$1FFF`, it decoded `$8000-$9FFF` for ~10 ns;
       through `~VCRAM-SELECT` that reset U522 (BLANK): dark dashes
       whenever code ran low in RAM (every application). The V4 has the
       same decode (OSM09_V3 U5 + U1), filtered by J6 and the backplane.
    2. Font EEPROM U515 OE to GND (it was `~LOAD`: one pixel, shorter
       than its tOE): through the graphic-mode 74HC157s U507/U509 (never
       soldered on the V4) the 166 loaded the previous glyph, so colours
       were exactly one cell ahead. CRT2 has the same latent OE gating.
  - **Graphic mode** (mono only, `$A120` D3 = GRAPH), tried on the board
    on 2026-11-15 with `tools/tele/essai_graphique.asm` (through TELE,
    page 1 `$1000`, A = seconds): U507/U509 give the 166 the char-RAM
    byte instead of the font (bit 7 = leftmost pixel), U514 puts RA0-3 on
    A11-A14 of the char RAM. Pixel byte of cell c, scan line r (0-15) at
    char-RAM address A = r x 2048 + (c mod 2048); the CPU reaches A with
    video page (`$A120` D0-D2) = A / 4096 and address `$8000 + 2 x (A
    mod 4096)`. 2048 cells = 25.6 rows: 640 x 400 useful, rows 26-29
    repeat the top. Colour stays per cell (colour RAM, page 0). The odd
    bytes of pages 1-7 are not displayed; those of `$9000-$9FFF` in page 0
    are the colours of rows 26-29 (keep them `$08`).
  - **The BIOS graphic mode** (`bios/graphe.asm`, BIOS2; service
    `sys_Graphe`, B = function, X = parameter block of signed words, A =
    mode or attribute; functions and exact effects in
    `tools/graphe/graphe.py`): the image is DRAWN in RAM page 3 (line y at
    y x 80, 32 000 bytes; the 8 x 8 font `/BIN/POLICE8`, made by
    `graphe.py --fichier` from `video/font_osm39.bin`, at `$7D00`). The
    service switches to page 3 (`current_page` follows) on its own stack
    `gr_pile` (the caller's may be in its page), marks each changed line in
    `gr_sale` AFTER writing it. The VSYNC IRQ (`X_Gr_IRQ`, first thing in
    `handler_IRQ` while `gr_actif`; console, cursor and spinner skipped):
    in the window, copies the lines prepared the frame before (3 by `TFM`
    of point:`$08` pairs, measured 1528 cycles; an r = 0 line alone, every
    other byte, since page 0's odd bytes are the cell colours) or one step
    of the colour task (64 cells); after the window, prepares the next
    marked lines into `gfx_tampon` (reading page 3 on stack `gr_pirq`).
    Whole screen: ~150 frames (2.5 s). Bench on the board:
    `tools/tele/essai_graphe.asm`. Demo: `cmd/GRAPHE`. Proven by
    `make -C test graphe`. BBC BASIC uses it in `MODE 0`. Not yet: scrolling.
  - `cmd/NEIGE` (both boards) is the bench that found them: white screen,
    IRQ masked, it polls the 68B40's frame flag itself and reads the VRAM
    after a delay set in lines (window after the frame signal: 34 lines
    on mono, 35 on V4). Modes: A waits in page-1 RAM, B in system RAM
    (`gfx_tampon`), C reads page-1 RAM for 3/4 of the frame, D the same
    loop at `$4000` (A14 = 1: no false decode). `stage9_mono` row 3 (X red,
    O green) checks the colour alignment.
- **VRAM write budget (mono, measured 2026-11-20** with
  `tools/tele/essai_cycles.asm` through TELE: IRQ masked, it counts a
  14-cycle loop between frame flags, 2196 turns = 30 751 cycles): the CPU
  may touch the VRAM only in the window after the frame signal, **~1990
  cycles** (34 lines, `cmd/NEIGE`); the BIOS IRQ takes ~250 of them at
  rest, so a program has **~1700 cycles per frame**. `TFM` = 6 + 3 per
  byte (one Terminal row, 152 bytes: 467); a cell per `STD ,X++` loop =
  12 cycles (76 cells: 920). BIOS IRQ per frame while the Terminal
  scrolls: 1316, 1792 on the frame that ended a scroll (row copy + row
  erased cell by cell); since 2026-11-20 `Zone_IRQ` erases the row by an
  overlapping `TFM` (first cell, then source = destination - 2: 481
  instead of 920 cycles). OSM-VISION's file list
  (`Draw_FileList`, `Update_List`) used to write 16 rows cell by cell in
  one go (~6200 estimated cycles: interference at the top of the screen
  while scrolling); on mono it now composes rows in RAM (`DFL_Prepare`,
  `DFL_Buf`) and copies them by `TFM` (`DFL_Copie`), checking `WinAcc`
  BEFORE each row (an already-synchronised caller gets a `Sync_Yield`
  after the preparation, which would eat its window). `lib/vision.asm`
  `Mono_Budget` is predictive: after a row it yields if one more row of
  the same cost would not fit (`Draw_Window` mono counts every row,
  bottom, shadow and title included). `Sync_Begin` zeroes `WinAcc`.
  `vis_Text` (`Put_Text`) costs ~32 cycles per character on mono: ONE
  80-character line overflows the window. Long lines go through
  `vis_Prep` (compose char:attr cells into `VisTxt` in RAM, outside the
  sync, several calls to overlay a highlighted cell or the cursor) then
  `vis_Ligne` (one `TFM` inside the sync, budget counted): CALC and EDIT
  use them (their worst write went from 4380 / 2716 to ~1200 estimated
  cycles). Use them in any app that writes long lines. The BIOS loading
  spinner is drawn by the VSYNC IRQ (`Spin_IRQ`, see SD card). `Draw_Base_UI` (whole screen, startup and after an
  app) still writes unsynchronised.
- 68B45 CRTC at `$A100/$A101`. **V4 hardware (archived 2026-11-18; from
  2026-10-10 the board carried "OSM39 V4.00")**: U126 A0 is wired to a12, so characters are at
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
    With the RTC card, the status bar also shows `JJ/MM/AAAA HH:MM` at
    row 23, column 25 (`HOR_COL`): `Hor_Lecture`, before the frame wait,
    every 60 frames, `Hor_Etat` first (no card: port A reads `$FF` and
    `Hor_LitDate` would wait for UIP = 0 forever), then `Hor_LitDate`;
    `Hor_Affiche`, right after the wait, writes it (the Clouris pointer
    on that row is removed first); `Draw_Status` redraws it. Read only:
    nothing is ever written to the chip.
  - **Clouris** (the user's touch mouse: 6 nails + a palm plate at GND,
    outputs on AY port A: J602 of OSM39_mono, J104 of SD-KBD-SON, same
    pins, odd = port A: IOA0 17 up, IOA1 15 right, IOA2 13 down, IOA3 11
    left, IOA4 9 centre, IOA5 7 thumb click; +5 V 1-2, GND 19-20).
    Its board (KiCad `clouris/`, J7: 1 +5 V, 2-7 nails J1-J6 in that
    order, 8 GND) puts a PNP (S9015; a BC516 Darlington on the schematic was
    worse: floating base, too much gain) before each 74HC14 gate:
    touch = bit **0**, rest and nothing plugged both read `$FF`.
    `CLOU_INVERSE` (`lib/clouris.asm`, `cmd/cloutest.asm`) = 1 for it,
    0 for the first hand-wired build (touch = 1, rest `$C0`). Wiring
    table in the manual ("Brancher la Clouris").
    `lib/clouris.asm` `Clou_Lit` (once per frame: contact seen on 2
    frames, a step at once then every 3 frames after 12, edges for
    centre/thumb). Its first call probes the AY (`Clou_Sonde`: `$05` then
    `$0A` written to R1 and read back, R1 restored): without the chip,
    port A reads the empty bus, i.e. fingers everywhere, and OSMVISION
    froze on the pointer (V4 with its AY pulled, 2026-11-18); no AY, no
    contact ever. OSMVISION's `Event_Loop` polls `sys_kbd_poll` (dropping
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
    (`CD SRC`, `ASM GLOUTON.ASM /GAMES/GLOUTON`); `MUSIQUE/` songs for AYJOUE; `JEUX/` the Z-machine stories found in `~/Documents/zmachine` and its subfolders (not in the repo, skipped if absent); `BUDGET/` created empty
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
  (A 440 = 262). Ports A/B go to J104 (J602 on mono). The first chip had
  a dead R9 (channel B volume, always `00`, B silent). Replaced on
  2026-11-20 on OSM39_mono by a salvaged chip marked Microchip: `AYTEST`
  28/28, 440 Hz identical on A, B and C by ear. Through TELE, 1195 random
  read-backs: all right except R9, 5/91 losing one low bit (`0E` -> `0C`,
  `05` -> `04`), never twice in a row, 96/96 in a targeted run; not
  audible. The software still plays two voices (A, C) everywhere: B is
  free for a third voice.
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
  - `Fs_ReadBlk`/`Fs_WriteBlk` keep only B: the driver leaves X at the
    end of `SD_BUFFER`, W = 0 and Y = its wait counter. Save what you
    need around them (BIOS2 never loaded on the board because
    `Ext_Charge` kept its copy pointer in Y). The verifiers' card model
    (`Machine.sd()`) clobbers the same registers.
  - Diagnostics (with `MONITEUR`): `M C879` = last SD error code (`sd_err`),
    `C87A` = retries since boot (`sd_retry`).
  - A long transfer shows a spinner top-right (`L`/`E`, then `| / - \`).
    `Fs_Spin`/`Fs_Spin_End` only REQUEST (`spin_on`: bit 0 shown, bit 7
    draw, bit 6 restore); `Spin_IRQ`, early in `handler_IRQ`, writes the
    VRAM. `Fs_Spin_End` waits (one frame) for the restore. A caller with
    IRQ masked gets no spinner (if it was already shown, `Fs_Spin_End`
    restores it directly).
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
  - `tools/tele/depose.py FILE /FOLDER/NAME [rw|rwx|rwxa] [page:addr]`
    puts a PC file on the board's card through TELE (file in page 1 at
    `$2000`, max 24 KB; Format_Filename_83, FS_DeleteFile if it exists,
    FS_SaveFile, FS_SetLoad, FS_SetAttributes, entry read back). The folder
    must exist.
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
  - Keys give accents in Latin-1 (é = `$E9`), the font is CP437 (é =
    `$82`). The keyboard stays Latin-1 (in CP437, `$80-$8B` are é à ç è ê:
    they would collide with the special keys). `lib/vision.asm`
    `Put_Text` (so `vis_Text`, `vis_Input`) translates `$A0-$FF` while
    drawing, table `lib/latin_cp437.inc` from `video/latin_cp437.py`
    (`--inc`, never edit; missing capitals fall back to their base
    letter). `vis_Input` accepts `$A0-$FF` except with `INP_MAJ` (file
    names stay ASCII). Files typed on the machine are Latin-1. The BIOS
    console (`PrintChar`: SHELL, BBC BASIC, FORTH) translates too, since
    2026-11-20, at DRAW time: the IRQ calls `Con_Lat` (EPROM, `bios/IT.asm`,
    same `Tab_LatCp`) just before writing the cell, in both the full-screen
    and the zone paths. Not in `PrintChar`: in CP437 é = `$82` would land
    on the `$80-$83` arrow codes the IRQ interprets.
    MINITEL, PAROLE, ZMACHINE have their own tables.
  - Dead keys (since 2026-11-21): the `^` key (PS/2 `$54`; the tables had it at `$53` until 2026-11-21, so it never armed on the board)
    and Shift+`^` (`¨`, `$A8`) return nothing and wait (`kbd_mort`); a
    vowel gives â ê î ô û / ä ë ï ö ü ÿ and capitals (Latin-1,
    `tablemorte`), Space the accent alone, any other key (AltGr, arrows
    included) the accent then that key on the next call (`kbd_suite`).
    Detected by the character, so AltGr+ç (`^`) stays a plain `^`.
    Nothing clears them on `scan_keyboard` entry: `NEW_CODE` = 0 is the
    normal state of an empty queue (clearing there lost every accent on
    the board, 2026-11-21).
  - A program that is busy for a frame (MINITEL) must use `sys_kbd_poll`:
    with one slot, a late reader lost make codes (keys came out one key
    late). Decoding in `keyboard.asm` is ordinary PS/2.
- **Clock (MC146818) on the PIA connector** (V3 `J4`, mono `J102`; board
  in the KiCad repo `RTC/`): PA0-7 = AD0-7, CA2 = AS, PB0 = DS, PB1 = R/W
  (10k pull-ups), CA1 = /IRQ (10k pull-up), 18650 behind a Schottky,
  charged off-board. The bus is too fast for the chip (tcyc >= 953 ns),
  so `lib/horloge.asm` drives it by hand in Motorola mode (DS low when AS
  falls); AS and R/W move only while DS is low; PA is an input only while
  DS = 1 on a read. Time in BCD, 24 h, years 20xx; reads wait for UIP = 0
  and repeat until two passes agree (`Hor_LitDate`); `cmd/HORLOGE` reads
  or sets it (weekday computed). CRA keeps its IRQ bits at 0: the PIA's
  IRQs go to FIRQ, whose handler is a bare `RTI`. `main` sets CRA `$34`
  (CA2 output low; it was `$0C`, a CA2 input with its IRQ enabled), and
  writes ORB = `$02` BEFORE DDRB = `$FF`: after a reset PB is an input,
  the pull-ups hold DS = R/W = 1, and outputs with ORB = 0 dropped both
  at once, a spurious write into the chip's last latched register
  (register B -> `$FF`: clock frozen, "pas réglée") on every RESET.
  `Hor_Init` selects ORB the same way before touching DDRB.
  - Tried on the board (2026-11-08) with a DS1287 (1989) on a breadboard,
    through TELE: reads, writes, setting, ticks in step with the PC, time
    kept 35 min powered off. The DS1287 needs MOT (pin 1) at VCC (internal
    ~20k pull-down = Intel mode), is inaccessible below 4.25 V and for
    200 ms after power-up, and its VRT bit, once 0, stays 0 (so HORLOGE
    always says the battery failed). The MC146818 did not tick there
    (salvaged crystal, not proven). A badly soldered R/W gave "reads
    right, every write ignored".
- `bios/verifie_ext.py` (in the BIOS build): no EPROM code names a BIOS2
  label except through `ExtV`.
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
- `verifie_fs.Machine` keeps the AY registers (`ay_regs`, read back through
  `AY_ADR` with the chip's bit widths; R14 = `lit_port_a()`); `ay_present =
  False` makes `AY_ADR` read the empty bus (`$50`).
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
repo after re-plugging.

Second backup (since 2026-11-13): two PRIVATE GitHub repos, `osm39-prive`
and `osm09-kicad-prive` (account `christophetoularastel-eng`). In both
working repos `origin` has two push URLs (the stick, then GitHub), so a
plain `git push` feeds both; the remote `github` reaches GitHub alone
(`git push github master` when the stick is unplugged). `user.email` is the
GitHub no-reply address in these two repos: GitHub refuses pushes exposing
a private e-mail. `core.fileMode false` on the bare repo only. Never write
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
- `games/Makefile clean` references an undefined `$(SONDE_OBJ)`.
- `update_includes.py`: six `page_copy_*` symbols, all "not found in map".
