#!/usr/bin/env python3
# ===================================================================
# verifie_farcall.py - La passerelle entre pages (bios/farcall.asm)
# ===================================================================
# Fait tourner le VRAI BIOS (bios/osm39.bin) dans l'émulateur de
# verifie_fs.py (4 pages de 32 Ko derrière $A0C0), avec de petites
# fonctions écrites en code machine dans les pages 2 et 3, appelées
# depuis du code en page 0 par FAR_CALL ($FFE0) et FAR_CALLN ($FFE3).
# Vérifie : la table de sauts est bien en $FFE0/$FFE3 ; l'appelée tourne
# dans SA page (latch et current_page) ; B, Y, U passent à l'aller, D,
# X, Y, U et la retenue au retour ; la page de l'appelant revient ; un
# appel imbriqué (page 2 -> page 3) ; FAR_CALLN suit la table en $0000 ;
# page > 3 refusée (C = 1, rien n'est appelé).
#   make -C bios && python3 test/verifie_farcall.py
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402

FAR_CALL, FAR_CALLN = 0xFFE0, 0xFFE3


def main():
    s = v.sym()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    verifie(s.get('rom_FarCall') == FAR_CALL and s.get('rom_FarCallN') == FAR_CALLN,
            'table de sauts en $FFE0 (FAR_CALL) et $FFE3 (FAR_CALLN)')

    m = v.Machine(os.devnull, s)
    cp = s['current_page']
    hi, lo = cp >> 8, cp & 0xFF
    # --- page 2 : table FDB en $0000, fonctions en $0100 et $0200 ---
    p2 = m.banks[2]
    p2[0:4] = bytes([0x01, 0x00, 0x02, 0x00])
    # f0 ($0100) : note sa page vue (STA $1002), puis D = Y + 1, X = U, C = 1
    p2[0x100:0x110] = bytes([
        0xB6, hi, lo,           # LDA current_page
        0xB7, 0x10, 0x02,       # STA $1002 (dans la page 2 : tracé par wr8)
        0x1F, 0x20,             # TFR Y,D
        0xC3, 0x00, 0x01,       # ADDD #1
        0x1F, 0x31,             # TFR U,X
        0x1A, 0x01,             # ORCC #1
        0x39])                  # RTS
    # f1 ($0200) : appel imbriqué vers la page 3, $0100 ; rend B = page vue là-bas
    p2[0x200:0x209] = bytes([
        0x86, 0x03,             # LDA #3
        0x8E, 0x01, 0x00,       # LDX #$0100
        0xBD, 0xFF, 0xE0,       # JSR FAR_CALL
        0x39])                  # RTS
    # page 3, $0100 : B = current_page vue de là-bas, C = 0
    m.banks[3][0x100:0x108] = bytes([
        0xB6, hi, lo,           # LDA current_page
        0x1F, 0x89,             # TFR A,B
        0x1C, 0xFE,             # ANDCC #$FE
        0x39])                  # RTS

    pages_vues = []
    orig_wr8 = m.wr8

    def wr8(a, val):
        if a & 0xFFFF == 0x1002:
            pages_vues.append((val, m.page))
        orig_wr8(a, val)
    m.wr8 = wr8

    def appel(adr, page_appelant=0, **regs):
        m.mem[cp] = page_appelant
        m.page = page_appelant
        for r, val in regs.items():
            setattr(m, r, val)
        ok = v.appelle(m, adr)
        return ok

    # 1. FAR_CALL page 2, f0 : passage des registres, page vue, retour
    ok = appel(FAR_CALL, a=2, x=0x0100, y=0x3456, u=0x789A, b=0x12)
    verifie(not ok, 'la retenue de l\'appelée revient (C = 1)')
    verifie(((m.a << 8) | m.b) == 0x3457 and m.x == 0x789A and m.u == 0x789A and m.y == 0x3456,
            'Y et U passent, D = Y + 1 et X = U reviennent')
    verifie(pages_vues and pages_vues[-1] == (2, 2), 'l\'appelée tourne en page 2 (latch et current_page)')
    verifie(m.page == 0 and m.mem[cp] == 0, 'page 0 de l\'appelant rétablie (latch et current_page)')

    # 2. FAR_CALLN page 2, fonction 0 depuis la page 1
    pages_vues.clear()
    ok = appel(FAR_CALLN, page_appelant=1, a=2, b=0, y=0x0FFF, u=1)
    verifie(not ok and ((m.a << 8) | m.b) == 0x1000 and pages_vues == [(2, 2)] and m.page == 1
            and m.mem[cp] == 1, 'FAR_CALLN : table de la page 2, appelant en page 1 rétabli')

    # 3. appel imbriqué : page 0 -> page 2 (f1) -> page 3
    ok = appel(FAR_CALLN, a=2, b=1)
    verifie(ok and m.b == 3, 'appel imbriqué page 2 -> page 3 : l\'appelée voit sa page (B = 3), C = 0')
    verifie(m.page == 0 and m.mem[cp] == 0, 'retour en page 0 après deux bascules')

    # 4. page > 3 : rien n'est appelé
    pages_vues.clear()
    ok = appel(FAR_CALL, a=4, x=0x0100)
    verifie(not ok and not pages_vues and m.page == 0 and not m.mauvaise_page,
            'page 4 refusée : C = 1, aucun appel, aucune bascule')

    # 5. par la table du BIOS : JSR [sys_Far_Call], puis un emplacement libre
    rom, fin = s['table_function_rom'], s['table_function_rom_end']
    t = s['table_function_ram']
    for i in range(fin - rom):
        m.mem[t + i] = m.rd8(rom + i)
    verifie(fin - rom == s['table_function_ram_end'] - t,
            'table ROM et table RAM de même taille (réserve comprise)')

    def par_table(slot, **regs):
        p0 = m.banks[0]
        p0[0x300:0x305] = bytes([0xAD, 0x9F, slot >> 8, slot & 0xFF, 0x39])  # JSR [slot] / RTS
        return appel(0x0300, **regs)

    pages_vues.clear()
    ok = par_table(s['sys_Far_Call'], a=2, x=0x0100, y=0x00FF, u=0x55AA)
    verifie(not ok and ((m.a << 8) | m.b) == 0x0100 and m.x == 0x55AA and pages_vues == [(2, 2)]
            and m.page == 0, 'JSR [sys_Far_Call] : même passerelle que $FFE0')
    ok = par_table(s['sys_Far_CallN'], a=2, b=1)
    verifie(ok and m.b == 3 and m.page == 0, 'JSR [sys_Far_CallN] : même passerelle que $FFE3')
    libres = range(s['table_reserve'], s['table_function_ram_end'], 2)
    sans_effet = True
    for slot in libres:
        pages_vues.clear()
        ok = par_table(slot, a=2, x=0x0100, b=0x5A)
        sans_effet &= (not ok) and m.b == 0x5A and not pages_vues and m.page == 0
    verifie(len(libres) > 0 and sans_effet,
            '%d emplacement(s) libre(s) : C = 1, rien d\'appelé' % len(libres))

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
