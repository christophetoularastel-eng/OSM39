#!/usr/bin/env python3
"""Surveille l'insertion de cartes OSMFS et lance l'explorateur.

Usage :
    python3 egofs_watcher.py [--gui /chemin/egofs_gui.py] [--scan-existing]
    python3 egofs_watcher.py --check /dev/sdb

Fonctionnement :
    - Scanne régulièrement /sys/class/block pour repérer les nouveaux
      périphériques (disques complets ET partitions, ex. mmcblk0, mmcblk0p1).
    - Pour chaque nouveau périphérique, OSMFS_Core.detect() vérifie la
      signature OSMFS puis lance egofs_gui.py avec le périphérique en argument.
    - Sans argument, les périphériques déjà présents au démarrage sont
      ignorés ; avec --scan-existing, ils sont aussi vérifiés (mode test).
    - --check affiche un diagnostic de détection pour un périphérique donné.

Ne requiert pas de droits root, mais l'utilisateur doit pouvoir lire les
périphériques bruts : ajouter l'utilisateur au groupe 'disk' est la méthode
la plus fiable (sudo usermod -aG disk $USER puis reconnexion).

Installation au login : voir install.sh
"""
import os
import subprocess
import sys
import time

from egofs_core import OSMFS_Core

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_GUI = os.path.join(BASE_DIR, "egofs_gui.py")
POLL_INTERVAL = 2.0
SYS_BLOCK = "/sys/class/block"


def _whole_disk(name):
    """Un disque complet (sdb, mmcblk0) n'a pas de fichier 'partition'."""
    dev = os.path.join(SYS_BLOCK, name)
    return os.path.exists(dev) and not os.path.exists(os.path.join(dev, "partition"))


def _parent_disk(name):
    """Nom du disque parent d'un périphérique de bloc (sdb1->sdb,
    mmcblk0p1->mmcblk0) ; le disque complet est son propre parent."""
    if os.path.exists(os.path.join(SYS_BLOCK, name, "partition")):
        base = name.rstrip('0123456789')
        if base.endswith('p'):
            base = base[:-1]
        return base
    return name


def _list_devices():
    """Liste les périphériques de blocs (disques complets et partitions)."""
    try:
        names = os.listdir(SYS_BLOCK)
    except OSError:
        return []
    return [n for n in names if os.path.exists(os.path.join(SYS_BLOCK, n, "partition")) or _whole_disk(n)]


def _is_osmfs(name):
    """Détecte la signature OSMFS sur /dev/<name>."""
    return OSMFS_Core.detect(os.path.join("/dev", name))


def _launch_gui(gui_path, name):
    """Lance egofs_gui.py en lui passant le périphérique en argument."""
    try:
        subprocess.Popen([sys.executable, gui_path, os.path.join("/dev", name)])
    except OSError as e:
        print(f"[!] Impossible de lancer la GUI : {e}")


def check(device_path):
    """Diagnostic : accès en lecture puis résultat de detect()."""
    if not os.path.exists(device_path):
        print(f"[!] {device_path} introuvable.")
        return
    try:
        with open(device_path, 'rb') as fd:
            fd.seek(0, 2)
            size = fd.tell()
    except PermissionError:
        print(f"[!] {device_path} : ACCÈS REFUSÉ — ajoute ton utilisateur au "
              f"groupe 'disk' puis reconnecte-toi.")
        return
    except Exception as e:
        print(f"[!] {device_path} : erreur : {e}")
        return
    print(f"[*] {device_path} : {size} octets, lisible")
    print(f"[*] detect() : {OSMFS_Core.detect(device_path)}")


def main():
    gui_path = DEFAULT_GUI
    if "--gui" in sys.argv:
        gui_path = sys.argv[sys.argv.index("--gui") + 1]
    if "--check" in sys.argv:
        check(sys.argv[sys.argv.index("--check") + 1])
        return
    scan_existing = "--scan-existing" in sys.argv

    known = set()
    launched = set()
    if not scan_existing:
        known.update(_list_devices())

    print("[*] OSMFS Watcher actif — j'attends une carte SD...")
    while True:
        for name in _list_devices():
            if name in known:
                continue
            known.add(name)
            if _parent_disk(name) in launched:
                continue
            if _is_osmfs(name):
                print(f"[*] Carte OSMFS détectée : /dev/{name}")
                launched.add(_parent_disk(name))
                launched.add(name)
                _launch_gui(gui_path, name)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
