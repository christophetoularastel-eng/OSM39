#!/usr/bin/env bash
# Installe le watcher OSMFS en autostart de session et affiche les commandes
# pour faire taire l'erreur GNOME sur les cartes inconnues.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOSTART_DIR="$HOME/.config/autostart"
DESKTOP_FILE="$AUTOSTART_DIR/osmfs-watcher.desktop"

echo "[*] Vérification des modules Python..."
python3 -m py_compile "$DIR/egofs_core.py" "$DIR/egofs_gui.py" "$DIR/egofs_watcher.py"

echo "[*] Création de l'autostart..."
mkdir -p "$AUTOSTART_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=OSMFS Watcher
Comment=Surveille l'insertion de cartes OSMFS et lance l'explorateur
Exec=python3 "$DIR/egofs_watcher.py"
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
echo "[*] Autostart créé : $DESKTOP_FILE"

echo
echo "[*] Pour empêcher GNOME d'afficher une erreur sur les cartes inconnues :"
echo "    gsettings set org.gnome.desktop.media-handling automount false"
echo "    gsettings set org.gnome.desktop.media-handling automount-open false"
echo
echo "[*] Test immédiat (vérifie aussi les cartes déjà insérées) :"
echo "    python3 \"$DIR/egofs_watcher.py\" --scan-existing"
