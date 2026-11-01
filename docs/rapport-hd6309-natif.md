# Rapport : gain du passage d'OSM09 en mode natif HD6309

- **Date** : 3 août 2026
- **Périmètre** : BIOS, kernel, shell, Forth, commandes, Vi, lib, assembleur auto-hébergé
- **Méthode** : analyse statique des boucles chaudes (fichier:ligne) + tables de cycles
  HD6309 (manuel HD63B09EP, guide technique DeKok, tables Lomont, MAME `hd6309.cpp`
  validé sur silicium via XRoar/Fuzz6309, Wikipédia).

> Avertissement : aucune mesure sur matériel. Les chiffres sont des **estimations
> par analyse de code et par profil de cycles**, à valider par mesures avant/après
> (voir §7).

---

## 1. Synthèse exécutive

| Scénario | Gain estimé (mode natif seul) | Gain estimé (natif + réécritures 6309) |
|---|---|---|
| Forth : boucle de calcul + affichage de nombres | +10 à 15 % | **×1,5 à ×2,5** |
| Assembleur auto-hébergé (2 passes) | +8 à 12 % | +15 à 25 % |
| Vi : édition + rafraîchissement écran | +8 à 12 % | +15 à 25 % |
| Shell : parsing + exécution de commandes | +5 à 10 % | +5 à 15 % |
| TYPE / CP / MV / SAVE / LOAD (bloqués SD/terminal) | +0 à 5 % | +5 à 10 % |
| Kernel multitâche | neutre à +5 % | neutre à +5 % |

**Conclusion en trois points :**

1. **Le mode natif seul** (`LDMD #$01`, sans réécriture) rapporte typiquement
   **+8 à 12 % de débit CPU**. Les gains sont concentrés sur les accès direct/
   étendu/inhérent, TFR/EXG et les opérations 16 bits ; les boucles indexées 8 bits
   et les branches (l'essentiel des boucles chaîne/octet d'OSM09) ne gagnent **rien**.
   Comme OSM09 est **fortement limité par les I/O** (bit-bang SD, busy-wait ACIA,
   PS/2), le gain ressenti en usage interactif est plus proche de **+5 à 10 %**.
2. **Le vrai gain vient des nouvelles instructions 6309** (disponibles en émulation
   comme en natif) : division matérielle `DIVD`/`DIVQ`, multiplication `MULD`,
   transferts de blocs `TFM`, registres W/E/F et opérations 16 bits. Sur les routines
   ciblées (divisions par 10, copies de secteurs), le gain est de **×2 à ×7**.
3. **Le coût d'intégration est réel mais borné** : cadre d'interruption du kernel
   (+2 octets en natif), vecteur trap $FFF0, recalibrage des boucles de timing
   (PS/2, SPI), bascule des flags assembleur `--6809` → `--6309`. Le programme
   `cmd/CPU` déjà présent permet de détecter le 6309 et de conditionner le `LDMD`.

---

## 2. Le mode natif HD6309 en bref

- Activé par `LDMD #$01` (bit 0 du registre MD, l'instruction fait 5 cycles).
  Au reset, le 6309 démarre en **mode émulation** (comportement 6809 exact).
- **Toutes** les nouvelles instructions (registres E/F/W/Q, divisions, TFM, opérations
  inter-registres, bit-manipulation…) sont déjà utilisables **en mode émulation**.
  Le mode natif n'apporte que : cycles réduits + sauvegarde de W dans les cadres
  d'IRQ/SWI. La phrase « gain du passage en natif » recouvre donc deux choses
  distinctes : le gain *natif pur* (§3-4) et le gain *jeu d'instructions étendu* (§5),
  ce dernier étant le plus important.

Ce que change le mode natif :

| Élément | Effet |
|---|---|
| Cycles d'exécution | Réduction d'1 cycle sur la majorité des accès direct/étendu/inhérent et les op 16 bits ; **aucun** gain sur les accès indexés 8 bits, immédiats 8 bits et branches courtes |
| Cadre IRQ/SWI | +2 octets poussés par le matériel (W = E:F, juste après D). Frame : `[CC][A][B][E][F][DP][X][Y][U][PC]` au lieu de `[CC][A][B][DP][X][Y][U][PC]` (14 vs 12 octets) |
| SWI / IRQ | ~2 cycles de plus (poussée des 2 octets W) |
| FIRQ | Inchangé (frame rapide `[CC][PC]`, pas de W) |
| Boucles de timing | Exécutées plus vite → à recalibrer (PS/2, SPI) |
| Trappes | Instruction illégale / division par zéro → saut via vecteur **$FFF0** (voir §6) |

Exemples de coûts de cycles (émulation → natif), sources : Wikipédia « Hitachi 6309 »,
tables Lomont, HD63B09EP :

| Instruction | 6809 / 6309 émulé | 6309 natif | Écart |
|---|---|---|---|
| `LDA ,X` (indexé 8 bits) | 4 | 4 | 0 |
| `LDA >$xxxx` (étendu) | 5 | 4 | −1 |
| `LDA <$xx` (direct) | 4 | 3 | −1 |
| `LDA #$xx` (immédiat) | 2 | 2 | 0 |
| `LDD ,X` / `LDD #$xxxx` | 6 / 4 | 5 / 3 | −1 |
| `INCA`, `CLRA`, `LSRA`… (inhérent) | 2 | 1 | −1 |
| Branche courte prise / non prise | 3 / 2 | 3 / 2 | 0 |
| `LBRA` / `LBSR` | 5 / 9 | 4 / 7 | −1 / −2 |
| `TFR` | 6 | 4 | −2 |
| `EXG` | 8 | 5 | −3 |
| `MUL` (8×8) | 11 | 10 | −1 |
| `PSHS`/`PULS` (par mot) | 5+ | 4+ | −1 |
| `JSR` étendu / indexé | 8 / 7+ | 7 / 6+ | −1 |
| `RTS` | 5 | 5 | 0 |
| `SWI` | 19 | 21 | +2 |

---

## 3. Répartition du temps CPU d'OSM09 (analyse statique)

Classement des goulots d'étranglement, d'après l'exploration du code :

1. **BIOS `SD.asm` — I/O disque (le plus chaud en absolu)** : `SPI_Transfer_Byte`
   (`SD.asm:182-220`) en bit-bang : 8 itérations × 4-5 accès PIA par octet,
   512 octets/secteur, ≥ 2 secteurs par opération CP/MV. **~4096 itérations de
   bit-bang par secteur.** Les accès mémoire PIA dominent, pas le CPU.
2. **BIOS `PrintChar` (`main.asm:388-395`) — sortie terminal** : busy-wait ACIA +
   1 écriture par caractère. Toutes les chaînes passent par là.
3. **Forth — interprétation** : `Next_Word`/NEXT (`forth.asm:1335-1347`) exécute
   1 fetch + 1 `JSR`/`RTS` indirect par mot ; en mode interprété, recherche linéaire
   du dictionnaire (`find_Op_loop`). `Op_Print` + `Div16_Fast` (`forth.asm:336-400`)
   font une **vraie division restauratrice de 16 itérations à chaque chiffre**.
4. **ASM — assemblage** : recherche linéaire de 137 mnémoniques × 2 passes
   (`pi_srch`, `asm.asm:806-818`) + recherche de symboles (`SymFind`, 64 max).
5. **Vi — édition** : rafraîchissement écran complet par touche (`editor.asm:396-462`),
   conversions décimales soustractives (`Print_U8_Dec`), copies de lignes par octet.
6. **Shell + cmd** : légers ; attendent le clavier ou délèguent à la SD.
7. **Kernel** : négligeable en régime normal (~110 µs toutes les 10 ms, cf.
   `kernel.asm.old:364`).

---

## 4. Gain détaillé par composant (mode natif seul)

| Composant | Boucle chaude | Type | Gain natif seul | Remarque |
|---|---|---|---|---|
| BIOS SD | `SPI_Transfer_Byte` | I/O | +10 à 15 % | Accès PIA étendus : −1 cycle chacun ; la boucle reste dominée par les accès mémoire |
| BIOS FS | `Load_Copy`/`Save_Copy` (512 o) | CPU/octet | +0 à 5 % | Copie indexée 8 bits : pas de gain |
| BIOS `PrintDec16` | division soustractive (`main.asm:599-634`) | CPU | +5 à 10 % | Boucle indexée/branche ; surtout derrière `PrintChar` |
| BIOS `PrintChar`/`PrintString` | busy-wait ACIA | I/O | ~0 % | Le temps d'attente ne change pas |
| BIOS `page_copy`/`memcpy_32` | copies 32 o | CPU/octet | +0 à 5 % | Indexé 8 bits |
| Kernel | IRQ + scheduler + SVC | CPU | neutre | `SWI` +2 cycles ; `TFR`/`PSHS` −2/1 ; se neutralisent à peu près |
| Shell | `ParseCommand`/`strcmp` | CPU | +5 à 10 % | Indexé + branches |
| Forth | NEXT + primitives | CPU | +10 à 15 % | NEXT gagne ~4 cycles sur ~24 (`ldd ,x++` +1, `pshs` +1, `jsr [,x]` +1, `puls` +1) |
| Forth `Op_Print` | `Div16_Fast` (16 itér.) | CPU | +20 à 25 % | Les décalages/rotations inhérentes gagnent 1 cycle chacune |
| ASM | scan + recherches | CPU | +5 à 10 % | Indexé + branches |
| Vi | refresh + copies | CPU | +5 à 10 % | Idem |
| cmd TYPE/CP/MV | I/O | I/O | ~0 % | Bloqués par SD/terminal |

**Ordre de grandeur global (natif seul) : +8 à 12 % de débit CPU**, à pondérer par la
part de temps réellement bloquée en I/O (usage interactif ⇒ plutôt +5 à 10 %).
C'est cohérent avec le « 15 % typique » du manuel HD63B09EP et le « jusqu'à 30 % »
de Wikipédia, qu'atteignent les charges de calcul pur sans I/O.

---

## 5. Gains ciblés avec le jeu d'instructions étendu 6309

Les nouvelles instructions sont utilisables dès le mode émulation ; le mode natif les
accélère encore d'1 cycle. Ce sont elles qui offrent les gains les plus nets.

### 5.1 Division matérielle `DIVD`/`DIVQ` (le gain le plus spectaculaire)

OSM09 ne contient **aucune division par 10 « vraie »** sauf dans le Forth :
partout ailleurs ce sont des **divisions soustractives** (coût ∝ quotient) ou une
division restauratrice de 16 itérations (coût fixe ~200 cycles).

| Routine | Coût actuel | 6309 | Gain |
|---|---|---|---|
| Forth `Div16_Fast` (`forth.asm:374-400`) | ~200 cycles/division (16 itér.) | `DIVD` direct **26 cyc.** (base ≤ 255, donc ÷10 et ÷16) | **~×7** |
| BIOS `PrintDec16` (`main.asm:608-616`) | soustractif, jusqu'à ~600 cycles (÷1000 sur 0-65535) | `DIVQ` direct **35 cyc.** (32/16) | **×4 à ×7** (surtout masqué par le terminal) |
| Vi `Print_U8_Dec` (`editor.asm:340-391`) | soustractif | `DIVD` | **×4** |
| `Divide_Y_by_X_16` (`osmfs.asm:741-761`, `Vi/tools.asm:18-47`) | soustractif, coût ∝ quotient (potentiellement milliers de cycles si X petit) | `DIVQ` | **×20 à ×100** |

> Note silicium (MAME `hd6309.cpp`, validé XRoar) : `DIVD` place le quotient dans B
> et le reste dans A ; `DIVQ` place le quotient dans W et le reste dans D.

### 5.2 `TFM` pour les copies de blocs (×1,8)

Coût `TFM x+,y+` = **6 + 3·n** cycles contre ~5,5 cycles/octet pour une boucle
`lda ,x+ / sta ,y+ / decb / bne`. Candidates :

- Copies de secteurs FS (`Load_Copy`, `Save_Copy` : 512 o) → ~1540 cyc. au lieu de ~2800
- `memcpy_32_bytes` (`main.asm:733-742`), `page_copy` (32 o × N)
- Vi : insertion/suppression de lignes (`editor.asm:471-537`, `611-645`)
- Shell/`strcpy` : copies de noms

### 5.3 `MULD` pour les accumulations ×10 / ×16

`StringToNumber` (Forth `forth.asm:1968-1976`, shell `shell.asm:646-700`) font
`D = D*10` par 4 décalages + 2 additions (~30-40 cyc.) : `MULD #10` (**28 cyc.**) gagne
~2× sur la boucle de conversion.

### 5.4 Opérations 16 bits et registres W/E/F

- `LSRD`, `ASLD`, `ROLD`, `INCD`, `DECD`, `TSTD`, `CLRD`, `NEGD`, `COMD` remplacent
  2 instructions 8 bits en 1 (3/2 cyc. natif). Utiles pour les compteurs 16 bits des
  boucles de conversion et le pager du kernel (`mul` par TCB_SIZE).
- **W/E/F** : un second accumulateur 16 bits (E:F) et W pour réduire le trafic pile —
  très utile au Forth (garder le sommet de pile dans W), aux conversions hexa de
  l'ASM, et comme compteurs de boucles.
- `PSHSW`/`PULSW` : pousser/retirer W en 1 instruction.
- Opérations **inter-registres** (ADDR, SUBR, CMPR, ANDR, ORR, EORR : 4 cycles) pour
  les comparaisons de registres dans le Forth et l'ASM.
- Nouveaux modes d'adressage indexés : offset W, `[W]` indirect, W auto-incrément
  par 2 — utiles pour les interpréteurs (NEXT) et les tables.

### 5.5 Effet combiné

- **Forth orienté calcul + affichage** : NEXT +15 %, divisions ×7 ⇒ **×1,5 à ×2,5**
  selon la part de calcul vs I/O.
- **ASM** : passages réduits d'instructions (16 bits, inter-registres) ⇒ **+15 à 25 %**.
- **Vi** : `DIVD` sur les numéros de ligne + `TFM` sur les copies ⇒ **+15 à 25 %**.
- **FS** : `TFM` accélère la copie CPU, mais la SD bit-bang reste le facteur dominant.

---

## 6. Coûts et risques d'intégration (à ne pas sous-estimer)

1. **Cadre d'interruption du kernel (+2 octets en natif)** — c'est LE point bloquant.
   En natif, IRQ et SWI poussent `[CC][A][B][E][F][DP][X][Y][U][PC]` (14 octets).
   - `TaskCreate` (`kernel.asm.old:381-409`) doit créer des frames de 14 octets
     (E=F=0 par exemple).
   - Les offsets du cadre dans `Kernel_Panic` (`kernel.asm:100-153`) et toute
     manipulation manuelle de frame (yield, sleep) se décalent de 2 octets.
   - `Kernel_Switch` ne manipule que le SP ⇒ sans changement, mais il faut que les
     frames soient à la bonne taille pour que le `RTI` hardware soit cohérent.
   - L'ISR FIRQ PS/2 (`IT.asm`) est inchangée (frame rapide).
   - À surveiller : le kernel actuel (V7) est en cours de simplification ; partir du
     scheduler complet (`kernel.asm.old`) pour la migration.

2. **Vecteur de trappe $FFF0** : le 6309 saute à `$FFF0` sur instruction illégale
   ou division par zéro. Les vecteurs EPROM d'OSM09 occupent `$FFF2-$FFFF`
   (`bios/vectors.asm:288-296`) ; `$FFF0-$FFF1` n'est pas défini (probablement
   `$FFFF` = padding). Il faut placer un pointeur vers un handler (au minimum `RTS`,
   ou un handler qui loggue) en `$FFF0` dans la ROM, **sinon toute trappe part en
   vrille**. Tant qu'on n'exécute pas d'opcode illégal et qu'on vérifie la division
   par zéro, la trappe ne se déclenche pas — mais c'est un risque latent.

3. **Boucles de timing à recalibrer** (le mode natif les accélère) :
   - **PS/2** : `handler_FIRQ` (`IT.asm:35-102`) échantillonne l'horloge PS/2 en
     bit-bang — le plus sensible, à retester impérativement.
   - **SPI SD** : `SPI_Transfer_Byte` gagne ~13 %, ce qui accélère l'horloge SPI
     émise. À 2 MHz c'est très loin des limites de la carte (≤25 MHz), donc sans
     risque sauf cartes capricieuses ; à revalider.
   - Busy-waits ACIA (`PrintChar`) et `scan_keyboard` : sans conséquence (attente).

4. **Détection / gating du 6309** : `cmd/CPU` détecte déjà 6809 vs 6309 (test du
   registre W). Le `LDMD #$01` doit être conditionné à cette détection (ou émis avec
   `FCB $11,$3D,$01`, sans effet sur 6809 réel : $11 $3D = NOP 2 octets + NOP).
   En cas de 6809 réel, le système doit rester en émulation-compatible.

5. **Flags assembleur** : passer tout le projet de `--6809` à `--6309`
   (`Makefile` de chaque composant + AGENTS.md). `cmd/CPU` utilise déjà `--6309`.

6. **Registre MD** : à préserver (seuls `LDMD`/`BITMD`/`STMD` le touchent). Le
   bit FIRQ de MD peut rester au défaut (FIRQ rapide), OSM09 s'en sert déjà.

7. **Outils de test** : `asm/emu6809.py` est un émulateur **6809 uniquement**
   (les TFR W n'y sont pas décodés comme des registres W — comportement corrigé pour
   l'undefined, cf. les modifs de la session précédente, mais pas de registre W
   natif). Pour valider le mode natif, il faut un émulateur 6309 natif (XRoar,
   MAME) ou du matériel réel. Les tests hôte (`--selftest`, `--dis`) ne couvrent que
   le jeu 6809.

8. **Comportements 6809 « illégaux » utilisés** : la détection CPU repose sur des
   TFR non définis ; sur 6809 réel ils no-op, sur 6309 ils sont valides — aucun
   risque de trappe ici.

---

## 7. Plan de migration recommandé (par phases, avec mesures)

| Phase | Contenu | Livrable / critère de sortie |
|---|---|---|
| 0. Préparer les tests | Émulateur 6309 (XRoar/MAME) ; handler trap en `$FFF0` ; banc de mesures (temps Forth `.`, assemble d'un .asm de référence, TYPE/CP sur fichier connu, Vi) | Reproduire un état de référence mesuré en émulation |
| 1. Bascule en natif | `cmd/CPU` au boot (ou `FCB $11,$3D,$01`), `LDMD #$01` ; frames kernel 14 octets ; offset `Kernel_Panic` | Boot + multitâche + shell OK sur émulateur 6309 |
| 2. Recalibrage timing | PS/2 (ISR), SPI SD | Clavier et SD stables en natif |
| 3. Réécritures ciblées | `DIVD`/`DIVQ` (Forth `Op_Print`, BIOS `PrintDec16`, Vi, `Divide_Y_by_X_16`) ; `TFM` (copies FS, `memcpy_32`, Vi) ; `MULD` (StringToNumber) ; W/E/F + op 16 bits (Forth NEXT, pager kernel) | Mesures avant/après de chaque phase |
| 4. Généralisation | Flags `--6309` partout ; nouvelles adressages (offset W) si utile | `make` sans warning ; tests hôte + émulateur 6309 |

**Mesures recommandées** (comparer émulation vs natif) : affichage de 1000 nombres
déximaux en Forth, assemblage d'un fichier de référence, `TYPE`/`CP` d'un fichier,
rafraîchissement Vi.

---

## 8. Chiffres clés à retenir

- Mode natif seul : **+8 à 12 %** CPU (interactif : +5 à 10 %, I/O bloquées ≈ 0).
- Réécritures ciblées 6309 : **×2 à ×7** sur les divisions, **×1,8** sur les copies
  de blocs, **+15 à 25 %** sur Forth calcul, ASM et Vi.
- Coût d'intégration : frames kernel +2 octets, vecteur trap $FFF0, recalibrage
  PS/2/SPI, flags `--6309`, émulateur 6309 pour les tests.
- Le calcul est **I/O-bound** (SD bit-bang + terminal) : le gain wall-clock global
  du système est modeste ; il devient significatif pour les charges de calcul
  (Forth, ASM) et spécifiquement là où les divisions/copies sont utilisées.
