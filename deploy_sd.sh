#!/bin/sh
# ===================================================================
# deploy_sd.sh - Prépare les binaires finaux OSM39 pour déploiement
#
# Usage   : ./deploy_sd.sh [--no-build]
# Sortie  : dist/EPROM/osm39.bin   -> BIOS à graver en EPROM
#           dist/EPROM/font_osm39.bin -> police (EPROM des caractères)
#           dist/SD/<NOM>          -> fichiers à écrire sur la carte SD
#           dist/DEPLOY.md         -> récapitulatif : pour chaque fichier,
#                                     page, adresse et attributs à poser
#                                     dans l'entrée OSMFS (outil PC)
#
# Les adresses ne sont PAS déclarées ici : elles sont MESURÉES dans la
# map de chaque programme (section .code). BASIC, par exemple, est lié
# à $5A00 et non à $0000 ; BRIQUES, application d'OSM-VISION, à $4000.
# ===================================================================
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
EPROM="$DIST/EPROM"
SDDIR="$DIST/SD"

# --- 1. Construction de tous les composants (sauf --no-build) ---
# games/ et apps/ ne sont pas dans le Makefile racine : construits à part.
if [ "${1:-}" != "--no-build" ]; then
    echo "== Construction de tous les composants =="
    make -C "$ROOT"
    make -C "$ROOT/games"
    make -C "$ROOT/apps"
else
    echo "== Construction ignorée (--no-build) =="
fi

# --- 2. Manifeste : source, nom sur la SD, page, map, attributs ---
# PAGE : déclarée, pas mesurable. OSM-VISION et le shell passent au chargeur
# la page de l'entrée (g_find_fileInfo+24) : un programme console en page 0
# à $0000 ÉCRASERAIT OSM-VISION ou le shell, résidents en page 0 à $0000.
#   page 0 : OSMVISION ($0000), SHELL ($6000, le Terminal d'OSM-VISION) ;
#   page 1 : les programmes console, et les applications d'OSM-VISION
#            (BRIQUES, MIRE, CALC... : liées à $0000, OSM-VISION les charge
#            dans leur page et les appelle par FAR_CALL).
# Attributs OSMFS (+27) : bit0 x, bit1 w, bit2 r, bit3 caché, bit4 a.
#   rwx  = $07 : programme ;  rwxa = $17 : application d'OSM-VISION ;
#   rw   = $06 : fichier de données.
# Map « - » : pas un programme, adresse 0000.
# Rangement de la carte (OSMVISION seul à la racine : le démarrage l'y charge) :
#   BIN/    programmes système, et EDIT et CALC : OSM-VISION les lance par leur
#           nom pour ouvrir un .ASM ou un .CAL, et le BIOS ne cherche un
#           programme absent du dossier courant que dans /BIN puis à la racine
#   APPS/   applications (MINITEL, PAROLE...) ; GAMES/ les jeux
#   SRC/    sources assembleur (et BASIC) ; LIB/ et BIOS/ leurs INCLUDE : les
#           « ../lib/ui.inc » marchent tels quels depuis SRC
#           (CD SRC puis ASM GLOUTON.ASM /GAMES/GLOUTON)
#   DOC/    aides-mémoire en texte (EDIT.TXT, CALC.TXT : Entrée les ouvre)
#   MUSIQUE/ morceaux pour l'AY (.MUS, compilés par tools/ay/ay.py : Entrée
#           les joue par AYJOUE)
#   BUDGET/ créé vide (feuilles de CALC) : voir DOSSIERS
# BIOS/HARDWARE.INC et BIOS/SYSFUNC.INC vont avec CETTE EPROM.
# Dossiers créés sur la carte même s'ils restent vides
DOSSIERS="BUDGET"
# Fichiers retirés du système : effacés de la carte par egofs_deploy.py
SUPPRIMER="BIN/VI"
MANIFEST="
osmvision/OSMVISION   OSMVISION  0  osmvision/OSMVISION.map  rwx
shell/SHELL           BIN/SHELL  0  shell/SHELL.map          rwx
forth/FORTH           BIN/FORTH  1  forth/FORTH.map          rwx
cmd/TYPE              BIN/TYPE   1  cmd/TYPE.map             rwx
cmd/CP                BIN/CP     1  cmd/CP.map               rwx
cmd/MV                BIN/MV     1  cmd/MV.map               rwx
cmd/SIZE              BIN/SIZE   1  cmd/SIZE.map             rwx
cmd/CPU               BIN/CPU    1  cmd/CPU.map              rwx
cmd/RM                BIN/RM     1  cmd/RM.map               rwx
cmd/CD                BIN/CD     1  cmd/CD.map               rwx
cmd/MKDIR             BIN/MKDIR  1  cmd/MKDIR.map            rwx
cmd/PWD               BIN/PWD    1  cmd/PWD.map              rwx
cmd/LS                BIN/LS     1  cmd/LS.map               rwx
cmd/MONITEUR          BIN/MONITEUR 1  cmd/MONITEUR.map         rwx
cmd/SDTEST            BIN/SDTEST 1  cmd/SDTEST.map           rwx
cmd/TELE              BIN/TELE   1  cmd/TELE.map             rwx
cmd/AYTEST            BIN/AYTEST 1  cmd/AYTEST.map           rwx
cmd/AYJOUE            BIN/AYJOUE 1  cmd/AYJOUE.map           rwx
cmd/CLOUTEST          BIN/CLOUTEST 1  cmd/CLOUTEST.map       rwx
asm/ASM               BIN/ASM    1  asm/ASM.map              rwx
games/BRIQUES          GAMES/BRIQUES 1  games/BRIQUES.map         rwxa
apps/MIRE             APPS/MIRE   1  apps/MIRE.map            rwxa
apps/ENVAHIS         GAMES/ENVAHIS 1  apps/ENVAHIS.map        rwxa
apps/CALC             BIN/CALC   1  apps/CALC.map            rwxa
apps/EDIT             BIN/EDIT   1  apps/EDIT.map            rwxa
apps/GLOUTON           GAMES/GLOUTON 1  apps/GLOUTON.map          rwxa
apps/DONJON39           GAMES/DONJON39 1  apps/DONJON39.map          rwxa
apps/DONJON39.TXT       GAMES/DONJON39.TXT 1 -                       rw
apps/EDIT.TXT         DOC/EDIT.TXT 1 -                           rw
apps/CALC.TXT         DOC/CALC.TXT 1 -                           rw
tools/ay/morceaux/korobeiniki.MUS MUSIQUE/KOROBEINIKI.MUS 1 -   rw
apps/SON              APPS/SON    1  apps/SON.map             rwxa
apps/PAROLE           APPS/PAROLE 1  apps/PAROLE.map          rwxa
apps/PONT             APPS/PONT   1  apps/PONT.map            rwxa
apps/MINITEL          APPS/MINITEL 1  apps/MINITEL.map         rwxa
apps/PONT2            APPS/PONT2  2  apps/PONT2.map           rw
apps/PONT3            APPS/PONT3  3  apps/PONT3.map           rw
asm/test/hello.asm    SRC/HELLO.ASM 1  -                        rw
apps/glouton.asm       SRC/GLOUTON.ASM 1  -                   rw
apps/glout_data.inc  SRC/GLOUT_DATA.INC 1 -               rw
apps/mire.asm         SRC/MIRE.ASM 1  -                      rw
bios/hardware.inc     BIOS/HARDWARE.INC 1 -                  rw
bios/sysfunc.inc      BIOS/SYSFUNC.INC 1  -                  rw
lib/ui.inc            LIB/UI.INC     1  -                    rw
lib/vis.inc           LIB/VIS.INC    1  -                    rw
lib/snd.inc           LIB/SND.INC    1  -                    rw
lib/str.asm           LIB/STR.ASM    1  -                    rw
lib/vision.asm        LIB/VISION.ASM 1  -                    rw
lib/vram.asm          LIB/VRAM.ASM   1  -                    rw
lib/snd.asm           LIB/SND.ASM    1  -                    rw
"

attr_hex() {
    case "$1" in
        rwx)  echo '$07' ;;
        rwxa) echo '$17' ;;
        rw)   echo '$06' ;;
        *)   echo "ERREUR : attributs inconnus '$1'" >&2; exit 1 ;;
    esac
}

# Adresse de chargement = plus basse adresse des sections .code de la map.
# C'est ce que contient le fichier brut (--format=raw) : une .bss placée
# ailleurs (BASIC : .bss à $0000) n'y figure pas.
adresse_code() {
    grep -E '^Section: \.code ' "$1" \
        | sed -E 's/.* load at ([0-9A-Fa-f]{4}),.*/\1/' \
        | sort | head -1
}

# --- 3. Vérification des fichiers attendus ---
[ -f "$ROOT/bios/osm39.bin" ] || { echo "ERREUR : bios/osm39.bin absent (make ?)" >&2; exit 1; }
echo "$MANIFEST" | while read -r src nom page map attr; do
    [ -n "$src" ] || continue
    [ -f "$ROOT/$src" ] || { echo "ERREUR : $src absent (make ?)" >&2; exit 1; }
    if [ "$map" != "-" ]; then
        [ -f "$ROOT/$map" ] || { echo "ERREUR : $map absente : relancer après 'make clean' pour la produire" >&2; exit 1; }
        [ -n "$(adresse_code "$ROOT/$map")" ] || { echo "ERREUR : pas de section .code dans $map" >&2; exit 1; }
    fi
    attr_hex "$attr" >/dev/null
    # Page 0, $0000-$3FFF : OSM-VISION et le shell y résident. Tout autre
    # programme chargé là les écraserait au lancement.
    if [ "$page" = "0" ] && [ "$map" != "-" ] && [ "${nom##*/}" != "OSMVISION" ] && [ "${nom##*/}" != "SHELL" ]; then
        if [ "$(printf '%d' "0x$(adresse_code "$ROOT/$map")")" -lt 16384 ]; then
            echo "ERREUR : $nom en page 0 sous \$4000 écraserait OSMVISION ou SHELL (page 1 ?)" >&2; exit 1
        fi
    fi
done

# --- 4. (Plus de contrôle des services vis_* : chaque application emporte
#        sa copie de lib/vision.asm et tourne dans sa page.) ---

# --- 5. Préparation des répertoires de sortie ---
rm -rf "$DIST"
mkdir -p "$EPROM" "$SDDIR"
cp "$ROOT/bios/osm39.bin" "$EPROM/osm39.bin"
cp "$ROOT/video/font_osm39.bin" "$EPROM/font_osm39.bin"
python3 "$ROOT/video/glyphes_ui.py" --verifie || exit 1
# dist/manifest.txt : une ligne par fichier, pour tools/egofs/egofs_deploy.py
#   NOM PAGE ADRESSE ATTRIBUTS   (adresse et attributs en hexa, sans $)
# Un fichier sans map (donnée) prend la page 0, l'adresse 0000.
echo "# NOM PAGE ADRESSE ATTRIBUTS (genere par deploy_sd.sh)" > "$DIST/manifest.txt"
# dist/dossiers.txt : dossiers créés même vides (egofs_deploy.py)
for d in $DOSSIERS; do echo "$d"; done > "$DIST/dossiers.txt"
# dist/supprimer.txt : fichiers à effacer de la carte (retirés du système)
for d in $SUPPRIMER; do echo "$d"; done > "$DIST/supprimer.txt"
echo "$MANIFEST" | while read -r src nom page map attr; do
    [ -n "$src" ] || continue
    mkdir -p "$(dirname "$SDDIR/$nom")"
    cp "$ROOT/$src" "$SDDIR/$nom"
    if [ "$map" = "-" ]; then adr="0000"; else adr="$(adresse_code "$ROOT/$map")"; fi
    echo "$nom $page $adr $(attr_hex "$attr" | tr -d '$')" >> "$DIST/manifest.txt"
done

# Nom chargé par BOOT : lu dans le BIOS, pas recopié ici.
KERNEL=$(grep -E '^KERNEL_FILENAME:' "$ROOT/bios/main.asm" | sed -E 's/.*FCC +"([^ "]*) *".*/\1/')

# --- 6. Récapitulatif de déploiement ---
{
    echo "# Déploiement OSM39"
    echo
    echo "Date de génération : $(date)"
    echo
    echo "## 1. EPROM (à graver / flasher)"
    echo
    echo "- \`EPROM/osm39.bin\` (BIOS) : \`sha256: $(sha256sum "$EPROM/osm39.bin" | cut -d' ' -f1)\`"
    echo "- \`EPROM/font_osm39.bin\` (police, EPROM des caractères) : \`sha256: $(sha256sum "$EPROM/font_osm39.bin" | cut -d' ' -f1)\`"
    echo
    echo "## 2. Carte SD (entrées OSMFS)"
    echo
    echo "Nom : 15 caractères, majuscules, complété par des espaces. Page et"
    echo "adresse : champs +24 et +25 de l'entrée. Attributs : champ +27"
    echo "(bit0 x, bit1 w, bit2 r, bit4 a = application d'OSM-VISION)."
    echo
    echo "| Fichier | Taille | Page | Adresse | Attributs | SHA256 |"
    echo "|---|---|---|---|---|---|"
    echo "$MANIFEST" | while read -r src nom page map attr; do
        [ -n "$src" ] || continue
        f="$SDDIR/$nom"
        size=$(stat -c %s "$f")
        sha=$(sha256sum "$f" | cut -d' ' -f1)
        if [ "$map" = "-" ]; then
            adr="-"
        else
            adr="\$$(adresse_code "$ROOT/$map")"
        fi
        printf '| %-15s | %6s o | %s | %s | %s (%s) | %s |\n' \
            "$nom" "$size" "$page" "$adr" "$attr" "$(attr_hex "$attr")" "$sha"
    done
    echo
    echo "Applications d'OSM-VISION : page 1, \$0000 (chacune avec sa copie de lib/vision.asm)."
    echo
    echo "### En une commande (recommandé)"
    echo
    echo "\`dist/manifest.txt\` reprend ce tableau. L'injecteur l'applique tel"
    echo "quel, remplace les fichiers déjà présents et pose l'attribut a :"
    echo
    echo "    python3 tools/egofs/egofs_deploy.py /dev/sdX"
    echo
    echo "### À la main, avec l'explorateur OSMFS (egofs_gui.py)"
    echo
    echo "1. Un fichier déjà présent sous le même nom est remplacé."
    echo "2. **Injecter par lots d'une même adresse** : la page et l'adresse sont"
    echo "   demandées une seule fois pour toute la sélection."
    echo "$MANIFEST" | while read -r src nom page map attr; do
        [ -n "$src" ] || continue
        [ "$map" = "-" ] && continue
        echo "$page:$(adresse_code "$ROOT/$map") $nom"
    done | sort | awk 'BEGIN { a = "-" } { if ($1 "" != a) { if (a != "-") print ""; split($1, k, ":"); printf "   - page %s, adresse $%s :", k[1], k[2]; a = $1 "" } printf " %s", $2 } END { print "" }'
    echo "   - SRC/*.ASM et leurs .INC/.ASM (dossiers SRC, LIB, BIOS) :"
    echo "     page 1, n'importe quelle adresse (des sources : sur la machine,"
    echo "     \`CD SRC\` puis \`ASM GLOUTON.ASM /GAMES/GLOUTON\`)."
    echo "   - dossier vide à créer : $DOSSIERS"
    echo "3. **Attribut a** : l'explorateur pose toujours \`rwx\`. Sur la machine,"
    echo "   dans le shell, faire \`CHMOD <NOM> +a\` pour chaque fichier \`rwxa\`."
    echo
    echo "## 3. Chaîne de boot"
    echo
    echo "1. Le BIOS (EPROM) démarre et affiche le moniteur. Il ne charge"
    echo "   aucun programme tout seul."
    echo "2. La commande \`BOOT\` du moniteur charge \`$KERNEL\` (RAM \$0000,"
    echo "   page 0) et l'exécute."
    echo "3. OSM-VISION liste la carte. Un programme (attribut x) est chargé à"
    echo "   son adresse et prend la console ; une application (attributs x+a)"
    echo "   est chargée à \$4000 et dessine dans OSM-VISION, qui reste résident."
    echo
    echo "Vérifier le contenu avec \`LS\` dans le shell."
} > "$DIST/DEPLOY.md"

echo
echo "== Déploiement prêt dans $DIST =="
echo "  BIOS EPROM : $EPROM/osm39.bin"
echo "  Carte SD   : $SDDIR/ (voir dist/DEPLOY.md)"
