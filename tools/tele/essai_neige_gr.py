#!/usr/bin/env python3
# ===================================================================
# essai_neige_gr.py - Lance essai_neige_gr.asm par TELE, les 5 modes à
# la suite (8 s chacun), en disant à l'écran du PC lequel tourne.
#   python3 tools/tele/essai_neige_gr.py [--cam DOSSIER] [modes...]   (défaut : 0 1 2 3 4)
# --cam : une webcam (/dev/video0, MJPEG 640 x 480, ffmpeg) filme 2 s au
# milieu de chaque mode : DOSSIER/modeN.mkv et 4 images DOSSIER/modeN_k.png
# TELE doit tourner sur la machine. Assembler d'abord :
#   lwasm --6309 --format=raw -o tools/tele/essai_neige_gr.bin tools/tele/essai_neige_gr.asm
# ===================================================================
import os
import subprocess
import sys
import threading
import time

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
from tele import Tele, Liaison           # noqa: E402

MODES = {0: 'rien (référence : image nette)',
         1: 'recopie de la VRAM sur elle-même, sans arrêt (octets inchangés)',
         2: 'barres qui défilent, écrites sans arrêt',
         3: 'lectures seules, sans arrêt',
         4: 'barres écrites seulement dans la fenêtre (480 octets par trame)'}
SECONDES = 8


def filme(dossier, m, attente=3.0, duree=2):
    time.sleep(attente)
    v = os.path.join(dossier, 'mode%d.mkv' % m)
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'v4l2',
                    '-input_format', 'mjpeg', '-video_size', '640x480', '-i', '/dev/video0',
                    '-t', str(duree), '-c', 'copy', v])
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', v,
                    '-vf', 'select=not(mod(n\\,12))', '-vsync', 'vfr', '-frames:v', '4',
                    os.path.join(dossier, 'mode%d_%%d.png' % m)])


def main():
    args = sys.argv[1:]
    cam = None
    if args[:1] == ['--cam']:
        cam, args = args[1], args[2:]
        os.makedirs(cam, exist_ok=True)
    modes = [int(m) for m in args] or sorted(MODES)
    t = Tele(Liaison('/dev/ttyUSB0'))
    t.ping()
    code = open(os.path.join(ICI, 'essai_neige_gr.bin'), 'rb').read()
    t.ecrit(1, 0x1000, code)
    assert t.lit(1, 0x1000, len(code)) == code, 'code mal chargé'
    for m in modes:
        print('mode %d : %s' % (m, MODES[m]), flush=True)
        f = threading.Thread(target=filme, args=(cam, m)) if cam else None
        if f:
            f.start()
        r = t.appel(0x1000, a=m, b=SECONDES, delai=SECONDES + 10)
        if f:
            f.join()
        print('         %d trames (attendu %d)' % (r['x'], SECONDES * 60), flush=True)
        time.sleep(2)


if __name__ == '__main__':
    main()
