# EDIT et CALC — mode d'emploi

Les deux applications se lancent depuis OSM-VISION et y reviennent en
quittant. Les touches ci-dessous sont celles du code (`apps/edit.asm`,
`apps/calc.asm`) : si l'une ne fait pas ce qui est écrit, c'est cette page
qui a tort.

Version courte sur la carte, sans accents : `DOC/EDIT.TXT` et
`DOC/CALC.TXT` (sources `apps/EDIT.TXT`, `apps/CALC.TXT`). Garder les trois
d'accord.

Dans les deux, une **ligne de saisie** (nom de fichier, contenu d'une
cellule) se tape au bout : Retour arrière efface le dernier caractère,
Entrée valide, Échap abandonne. Pas de déplacement dans la ligne.

---

## EDIT — éditeur de texte (touches WordStar)

**Lancer** : dans OSM-VISION, Entrée sur un `.ASM`, `.TXT` ou `.INC`, ou
l'action « Editer » du menu Espace. Dans le Terminal : `EDIT NOM.TXT`.
Sans nom, le texte est vide et le nom est demandé à la première sauvegarde.

### Sortir

| Touches | Effet |
|---|---|
| **Ctrl+K puis X** | **sauver et sortir** (reste dans EDIT si la sauvegarde échoue) |
| Ctrl+K puis S | sauver et continuer |
| Ctrl+K puis Q, ou **Échap** | sortir sans sauver (demande O/N si le texte est modifié) |
| Ctrl+K puis L | ouvrir un autre fichier (son nom est demandé ; O/N si modifié) |

Après Ctrl+K, la ligne de messages rappelle les choix. La lettre peut être
tapée en minuscule ou avec Ctrl (Ctrl+K Ctrl+X marche aussi). Une autre
touche annule.

### Se déplacer

| Touches | Effet |
|---|---|
| flèches, ou Ctrl+E / Ctrl+X / Ctrl+S / Ctrl+D | haut / bas / gauche / droite |
| Page préc., ou Ctrl+R | page précédente |
| Page suiv., ou Ctrl+C | page suivante |
| Début / Fin | début / fin de la ligne |
| Ctrl+Début, ou Ctrl+Q puis R | début du fichier |
| Ctrl+Fin, ou Ctrl+Q puis C | fin du fichier |

Attention : **Ctrl+C et Ctrl+X ne sont pas copier/couper** ici (WordStar :
page suivante et ligne suivante). Il n'y a pas de copier-coller de blocs.

### Écrire et effacer

| Touches | Effet |
|---|---|
| Entrée | coupe la ligne |
| Retour arrière | efface le caractère à gauche (joint les lignes en début de ligne) |
| Suppr, ou Ctrl+G | efface le caractère sous le curseur |
| Ctrl+Y | efface toute la ligne |
| Tab | insère une tabulation (affichée comme un seul espace) |

### Bon à savoir

- La ligne d'état montre le nom, la ligne, la colonne et `*modifie*` tant
  que le texte n'est pas sauvé.
- Une ligne plus large que l'écran (77 colonnes) défile horizontalement.
- Fichiers jusqu'à 65 279 octets (64 Ko moins 256). Le texte vit dans les
  pages de RAM 2 et 3.
- La sauvegarde garde les attributs du fichier. Fins de ligne : LF.

---

## CALC — tableur (façon VisiCalc)

**Lancer** : dans OSM-VISION, Entrée sur un `.CAL` (la feuille est lue),
ou lancer `CALC` (feuille vide, nom proposé `FEUILLE.CAL`).

Feuille de 26 colonnes (A à Z) × 50 lignes ; 8 colonnes et 17 lignes à
l'écran, la vue suit le curseur.

### Sortir

Sauver avec **/ puis S**, puis **Échap**. Si la feuille a changé depuis la
dernière lecture ou sauvegarde, Échap demande « Feuille non sauvee : quitter
quand meme ? (O/N) » : O quitte, une autre touche reste dans CALC.

### Touches

| Touches | Effet |
|---|---|
| flèches | changer de cellule |
| Page préc. / Page suiv. | 17 lignes plus haut / plus bas |
| Début | colonne A |
| Fin | dernière cellule remplie de la ligne |
| Ctrl+Début | A1 |
| Ctrl+Fin | dernière ligne et dernière colonne utilisées |
| un caractère | commence une **nouvelle** saisie (remplace la cellule) |
| Entrée | **modifie** la cellule (son texte actuel est repris) |
| Suppr | vide la cellule |
| / | menu des commandes (ci-dessous) |
| Échap | quitter (O/N si la feuille n'est pas sauvée) |

Une saisie validée par Entrée recalcule la feuille et descend d'une ligne.
Échap pendant la saisie l'abandonne.

### Commandes : / puis une lettre

| Lettre | Effet |
|---|---|
| S | sauver (nom demandé, prérempli) |
| L | lire une feuille (nom demandé) |
| B | vider la cellule |
| E | effacer toute la feuille (demande O/N) |

Une autre touche annule. Sauver remplace un fichier du même nom. Une
feuille sur la carte fait toujours 20 800 octets ; L refuse un autre
fichier (« Ce fichier n'est pas une feuille. »).

### Contenu d'une cellule (15 caractères au plus)

- **Libellé** : commence par une lettre. Pour un libellé qui commence par
  un chiffre, le précéder de `"` (ôté à l'affichage) : `"2026`.
- **Valeur** : tout le reste — un nombre ou une formule.
  - Nombres à 2 décimales fixes, virgule ou point : `12,50`, `-3`, `0.5`.
  - Opérateurs `+ - * /`, parenthèses, références `A1` à `Z50`.
  - Fonctions sur une plage : `@SUM`, `@MIN`, `@MAX`, `@AVG`, avec `...`
    ou `:` : `@SUM(A1...A9)`, `@AVG(B1:B5)`.
  - **Une formule qui commence par une référence doit commencer par `+`** :
    `+A1*2`. Tapé `A1*2`, c'est un libellé (il commence par une lettre).

### Affichage

- `ERREUR` : division par zéro, dépassement, syntaxe, ou référence à une
  cellule en erreur.
- `>>>>>>>>` : le nombre ne tient pas dans la colonne (8 caractères).
- « Calcul instable : reference circulaire ? » : la feuille ne s'est pas
  stabilisée en 10 passes de calcul (une cellule dépend d'elle-même).
- Les valeurs sont des entiers en centièmes : `1/3` donne `0,33`.
