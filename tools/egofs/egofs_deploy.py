#!/usr/bin/env python3
"""Injecte tout dist/SD sur une carte (ou une image) OSMFS, d'apres
dist/manifest.txt genere par deploy_sd.sh.

Usage :
    python3 egofs_deploy.py <peripherique_ou_image> [--dist <dossier>] [--oui]

Pour chaque ligne du manifeste (NOM PAGE ADRESSE ATTRIBUTS), le fichier
dist/SD/NOM est injecte avec sa page, son adresse et ses attributs
(bit 4 = application OSM-VISION compris). Un fichier deja present sous le
meme nom est remplace. Ensuite la carte est RELUE : chaque fichier doit y
etre une seule fois, avec la bonne page, la bonne adresse, les bons
attributs et un contenu identique octet pour octet.

Securites :
    - refuse un peripherique qui ne porte pas de systeme OSMFS (detect) ;
    - affiche le plan et demande confirmation, sauf avec --oui.
"""
import os
import sys
import tempfile

from egofs_core import OSMFS_Core

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIST = os.path.normpath(os.path.join(BASE_DIR, "..", "..", "dist"))


def read_manifest(dist):
    """Lit dist/manifest.txt : liste de (nom, page, adresse hexa, attributs)."""
    entries = []
    with open(os.path.join(dist, "manifest.txt"), encoding="ascii") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, page, addr, attr = line.split()
            entries.append((name, int(page), addr, int(attr, 16)))
    return entries


def verify(core, dist, entries):
    """Relit la carte : retourne la liste des ecarts (vide si tout va bien).
    Le cache du noyau est d'abord vide pour ce peripherique : sans cela, la
    relecture serait servie par le cache et ne prouverait rien sur la carte."""
    with open(core.device_path, "rb") as fd:
        os.posix_fadvise(fd.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
    problems = []
    files = core.list_files()
    for name, page, addr, attr in entries:
        found = [f for f in files if f["path"] == name]
        if len(found) != 1:
            problems.append(f"{name} : {len(found)} entrée(s) au lieu d'une")
            continue
        f = found[0]
        if f["page"] != page or int(f["addr"], 16) != int(addr, 16) \
           or f["attr"] != attr:
            problems.append(f"{name} : page {f['page']} adresse {f['addr']} "
                            f"attributs ${f['attr']:02X}, attendu page {page} "
                            f"adresse 0x{addr} attributs ${attr:02X}")
        local = os.path.join(dist, "SD", name)
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "relu.bin")
            core.extract_file(f["index"], out)
            with open(out, "rb") as a, open(local, "rb") as b:
                if a.read() != b.read():
                    problems.append(f"{name} : contenu relu différent de {local}")
    return problems


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print(__doc__)
        return 2
    device = args[0]
    dist = DEFAULT_DIST
    if "--dist" in args:
        dist = os.path.abspath(args[args.index("--dist") + 1])
    yes = "--oui" in args

    if not os.path.exists(device):
        print(f"[!] {device} introuvable.")
        return 1
    if not OSMFS_Core.detect(device):
        print(f"[!] {device} ne porte pas de système OSMFS : rien n'est écrit.")
        return 1

    try:
        entries = read_manifest(dist)
    except OSError as e:
        print(f"[!] Manifeste illisible ({e}) : lancer d'abord ./deploy_sd.sh")
        return 1
    for name, _, _, _ in entries:
        if not os.path.isfile(os.path.join(dist, "SD", name)):
            print(f"[!] {name} absent de {dist}/SD")
            return 1

    print(f"[*] {len(entries)} fichier(s) à écrire sur {device} :")
    for name, page, addr, attr in entries:
        print(f"      {name:<24} page {page}  adresse ${addr}  "
              f"attributs {OSMFS_Core._rwx_str(attr)} (${attr:02X})")
    if not yes:
        answer = input(f"Écrire sur {device} ? [o/N] ").strip().lower()
        if answer not in ("o", "oui"):
            print("[*] Abandon : rien n'est écrit.")
            return 1

    core = OSMFS_Core(device)
    # Un fichier du manifeste qui a changé de dossier (BIN/GLOUTON devenu
    # GAMES/GLOUTON, ou une copie d'avant les dossiers, à la racine) : son
    # ancienne copie est effacée. Seulement à la racine et dans les dossiers
    # que le manifeste remplit : les dossiers de l'utilisateur (BUDGET...)
    # ne sont jamais touchés.
    noms = {n for n, _, _, _ in entries}
    geres = {n.rsplit("/", 1)[0] for n in noms if "/" in n}
    base = {n.rsplit("/", 1)[-1] for n in noms}
    for f in core.list_files():
        dossier = f["path"].rsplit("/", 1)[0] if "/" in f["path"] else ""
        if not f["is_dir"] and f["path"] not in noms and f["name"] in base and \
           (dossier == "" or dossier in geres):
            core.delete_file(f["index"])
            print(f"[*] {f['path']} : ancienne copie effacée (rangée ailleurs).")
    try:
        with open(os.path.join(dist, "supprimer.txt"), encoding="ascii") as fd:
            retires = set(fd.read().split()) - noms
    except OSError:
        retires = set()
    for f in core.list_files():
        if not f["is_dir"] and f["path"] in retires:
            core.delete_file(f["index"])
            print(f"[*] {f['path']} : retiré du système, effacé.")
    try:
        with open(os.path.join(dist, "dossiers.txt"), encoding="ascii") as fd:
            for d in fd.read().split():
                if core.mkdir(d) is not None:
                    print(f"[*] dossier {d}/ présent.")
    except OSError:
        pass
    for name, page, addr, attr in entries:
        if not core.inject_file(os.path.join(dist, "SD", name), name,
                                page, addr, attr):
            print(f"[!] Échec de l'injection de {name} : arrêt.")
            return 1

    problems = verify(core, dist, entries)
    if problems:
        print("[!] La relecture de la carte ne correspond pas :")
        for p in problems:
            print(f"      {p}")
        return 1
    print(f"[*] {len(entries)} fichier(s) écrits et relus à l'identique "
          f"sur la carte : elle peut être retirée.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
