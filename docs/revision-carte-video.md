# Carte vidéo : notes pour la prochaine révision

État au 9 octobre 2026. Carte prototype (`video/CRT2.pdf`) avec des fils de
reprise qui passent au-dessus de U2 et longent la sortie VGA. Ces notes servent
au moment de router une carte définitive, probablement une seule grande carte
pour tout le système.

## Deux défauts d'affichage constatés

Ils ont été trouvés avec le banc `test/` (étapes 6 à 8) et avec MIRE (touches T
et P). Résumé dans `AGENTS.md`, section *Video*.

1. **Liseré d'un pixel** juste avant une cellule dont l'attribut diffère de sa
   voisine de gauche (exemple : trait bleu à gauche des briques de BRIQUES).
2. **Pointillés roses verticaux, fixes**, dans les cases dont le premier plan
   vaut 0 (bits 0 à 3 de l'attribut à zéro), dès qu'il y a du contenu ailleurs
   sur les mêmes lignes de balayage. Ils sont invisibles sur un écran tout
   noir. Contournement logiciel : utiliser `$20`/`$08` au lieu de `$20`/`$00`
   (BRIQUES `COLOR_BOARD`).

## Mesures au SmartScope (voie A = rouge, broche 1 ; déclenchement sur VSYNC, broche 14, + ~6 ms)

- Les pointillés sont de petites bosses d'environ 0,1 V (15 % du blanc).
- Des bosses semblables existent **pendant le retour de ligne**, alors que la
  vidéo y est forcée à 0 par BLANK (74HCT08). Elles ne passent donc pas par les
  données.
- VSYNC, qui devrait être plat, bruite par zones, et ces zones **changent de
  place** quand on change l'attribut du puits (`$00` → `$08`).
- Hypothèse retenue : bruit de commutation simultanée (rebond de masse ou
  d'alimentation) du bus de la RAM couleur. Entre `$8F` et `$00`, cinq bits
  basculent à la fois. Le bruit est couplé sur les lignes R/G/B, et le bit de
  luminosité (2N7000) change l'impédance de ces lignes.
- Non tranché : la part due aux longs fils de masse des sondes, et le chemin
  exact (logique ou analogique).

## À prévoir au routage

- Zone analogique (2N7000 Q1 à Q3, R1 à R8, prise VGA) **à l'écart** des bus de
  données, avec un retour de masse court ; plan de masse si possible.
- Découplage 100 nF **au pied** de U2 (74HC374, verrou d'attribut), U3
  (74HCT157, multiplexeur de couleur) et U122 (74HCT08) ; 10 µF près de la
  prise VGA.
- Empreintes de résistances série de 22 à 33 Ω sur le bus de données de la RAM
  couleur (straps si inutiles).
- Liseré : mesurer LOAD par rapport au chargement du 74HCT166 et à la sortie de
  U2. Pistes : verrou plus rapide (`74AC374` ou `74F374`), ou un pixel de retard
  sur le chemin de l'attribut.

## Pour valider la nouvelle carte

Lancer MIRE (`apps/mire.asm`) :

- **P**, essai 1 : aucun pointillé dans le puits ;
- **T**, étapes 1 à 3 : aucun liseré le long des parois.

Si tout est propre, `COLOR_BOARD` peut revenir à `$00`, mais rien n'y oblige.
