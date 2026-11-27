# Matériel en suspens — OSM39_mono

Les petits problèmes matériels connus et non réglés, à reprendre un par un.
Les détails techniques sont dans `AGENTS.md` (sections citées). Un point
réglé est retiré d'ici et noté dans `docs/historique.md`.

État au 26 novembre 2026.

## 1. Le 74HC165 de la carte SD se charge aussi en lecture

- **Constat** (mesuré sur la carte le 30 oct. 2026) : une lecture de
  `SD_DATA` (`$A148`) rend l'octet reçu au transfert précédent ET lance un
  nouvel échange SPI qui renvoie cet octet à la carte SD. Le schéma (et
  `tools/carte_sd_kbd_son/simule.py`) ne charge le 165 que sur les écritures.
- **Conséquence** : sans effet pendant que la carte parle, mais un `$00` lu
  après la réponse R1 de CMD24 est pris pour le début du bloc.
- **Contournement en place** (`bios/SD.asm`) : CMD24 envoyée « à l'aveugle »
  (8 x `$FF` écrits, R1 jamais lue) ; la réponse de données dit si
  l'écriture a réussi. Validé : 51 200 lectures, 20/20 écritures relues.
- **Schéma** (netlist relue le 26 nov. 2026) : `~SEL_WR` = R/W OU
  `~A148` (U607A, 74HC32 ; `~A148` du 74HC138 U604 validé par E) va sur
  SH/~LD du 165 (U614 broche 1) ; son entrée série (broche 10) est au
  +5 V : une lecture devrait renvoyer `$FF`. Pendant une lecture, le 595
  (U612, OE = `~SEL_RD`) met l'octet reçu sur le bus : si `~SEL_WR` est bas
  à ce moment, le 165 charge cet octet et le renvoie — exactement le
  symptôme. Le défaut étant systématique (pas un glitch de transition),
  piste principale : U607 broche 1 qui voit 0 en lecture — **pont de
  soudure entre les broches 1 et 2 de U607** (voisines), broche 1 en
  l'air, ou erreur de routage.
- **Test** : hors tension, U607 broche 1 ↔ broche 2 = circuit ouvert ;
  U607 broche 1 ↔ 6309 broche 32 (R/W) = 0 Ω. Sous tension : U607 broche 3
  doit rester à 1 pendant une boucle de lectures de `$A148` (carte SD
  désélectionnée).
- **Sur la mono** (27 nov. 2026) : U607 broche 1 ↔ broche 2 ouvert,
  broche 1 ↔ R/W du 6309 = 0 Ω (bon). Par TELE (`tools/tele/essai_sd.py`,
  secteur `$00100000`, restauré) : écriture avec lecture de R1 **en lent :
  3 sur 3 réussies** (réponse `E5`, relu identique) — sur la SD-KBD-SON
  elle échouait en lent comme en rapide. Le défaut était donc
  probablement propre à la carte SD-KBD-SON. En rapide, le module
  d'essai échoue même à l'aveugle (alors que le BIOS écrit à l'aveugle en
  rapide sans problème) et bloque la carte SD (CMD0 sans réponse jusqu'à
  ce qu'on la retire) : ses boucles rapides ne conviennent pas à la mono,
  rien à conclure pour le rapide.
- **À faire** : un essai « R1 lue » en rapide bâti sur les routines du
  BIOS ; s'il passe, ce point sort de la liste (le pilote peut garder
  CMD24 à l'aveugle, qui marche).
- AGENTS.md : « The SD card is on the hardware SPI ».

## 2. PCB de l'OSM39_mono à router

Trois modifications sont faites par fils sur la carte et dessinées dans le
schéma KiCad, pas encore sur le circuit imprimé :

1. `/8000-9FFF` validé par E (U103, porte 9/10 -> 8) : les tirets sombres
   du premier allumage ;
2. OE de l'EEPROM de police U515 à la masse : les couleurs décalées d'une
   case ;
3. RAM des couleurs U512 A11-A14 sur `RA11`-`RA14` : une couleur par
   ligne de 8 points en mode graphique (soudée et vérifiée sur la carte
   le 27 nov. 2026, `tools/tele/essai_8x1.asm`).

- AGENTS.md : « The board works », « Graphic mode ».

## 3. Deux défauts d'affichage

- **Frange** d'un pixel juste avant une case dont l'attribut diffère de sa
  voisine de gauche.
- **Traits pointillés roses** dans les cases dont le premier plan vaut 0,
  quand les mêmes lignes portent autre chose ailleurs. Contournement : un
  premier plan `$8` pour une case noire vide.
- Cause non cherchée ; suspect principal : la carte elle-même (fils
  rapportés, diaphonie).
- AGENTS.md : « Two hardware display defects ».

## 4. Neige quand le processeur touche la mémoire vidéo

- Un accès du processeur pendant l'affichage bascule les multiplexeurs
  d'adresse (`~VCRAM-SELECT`) ET remet à zéro U522 (`BLANK`) : noir pendant
  l'accès plus 2-3 cases. Le logiciel n'écrit que dans la fenêtre après le
  signal de trame (~1700 cycles par trame).
- Mesuré à la webcam le 25 nov. 2026 (`tools/tele/essai_neige_gr`).
- Pistes : RAM double port (IDT7007 / IDT7005, disponibilité non vérifiée),
  ou attente du 6309 par MRDY (il faudrait alors une horloge 1,8432 MHz
  séparée pour l'ACIA série, qui prend la sienne sur E).

## 5. AY-3-8910 : R9 perd parfois un bit

- Le registre R9 (volume de la voie B) relu perd de temps en temps un bit
  de poids faible (5 fois sur 91 dans un essai, jamais deux fois de suite).
  Inaudible. Le logiciel joue sur A et C.
- AGENTS.md : « AY-3-8910 on the SD-KBD-SON board ».

## 6. Police 28C256 (OSM City)

- La puce de police de 32 Ko (banque 1 : les tuiles d'OSM City) n'est pas
  encore montée : il faut aussi `$A120` D4-D5 vers A13-A14 de U515 (U525
  O4/O5 -> broches 26 et 1). Fichier prêt : `dist/EPROM/font_osm39_28c256.bin`.
- AGENTS.md : `apps/osmcity.asm`, « Tiles ».
