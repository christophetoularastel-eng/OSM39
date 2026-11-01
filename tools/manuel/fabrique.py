#!/usr/bin/env python3
# ===================================================================
# fabrique.py - docs/manuel/manuel.html -> docs/manuel/OSM39-manuel.pdf
# ===================================================================
# WeasyPrint dans tools/manuel/.venv (pas installé dans le système) :
#   python3 -m venv tools/manuel/.venv && tools/manuel/.venv/bin/pip install weasyprint
#   tools/manuel/.venv/bin/python tools/manuel/captures.py   # les écrans
#   tools/manuel/.venv/bin/python tools/manuel/fabrique.py   # le PDF (et police.py)
# Les polices (OFL) sont dans tools/manuel/polices, intégrées au PDF.
# ===================================================================
import os
import sys

from weasyprint import HTML

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import police                   # noqa: E402

RACINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(RACINE, 'docs', 'manuel', 'manuel.html')
SORTIE = os.path.join(RACINE, 'docs', 'manuel', 'OSM39-manuel.pdf')


def main():
    police.main()                     # les tableaux de la police, toujours à jour
    doc = HTML(SOURCE).render()
    doc.write_pdf(SORTIE)
    print('%s : %d pages' % (SORTIE, len(doc.pages)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
