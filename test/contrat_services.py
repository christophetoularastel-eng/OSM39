#!/usr/bin/env python3
# ===================================================================
# contrat_services.py - Le contrat des services du BIOS (source unique)
# ===================================================================
# Un élément par emplacement de table_function_ram, dans l'ordre :
#   num, nom, sys (nom de l'emplacement sans « sys_ »), entree, sortie
#   (textes), sortie_regs (registres qui portent une sortie), detruit
#   (registres que le service peut changer en plus : l'appelant ne doit
#   rien y laisser), note, scenarios (pour verifie_contrat.py).
# « Préservé » = tout registre ni sortie ni détruit, parmi A B E F X Y U
# (DP et la pile toujours). La retenue : C = 1 échec, C = 0 réussite, sauf
# mention contraire ; les autres bits de CC ne sont pas garantis.
# verifie_contrat.py mesure chaque service sur le vrai BIOS ; --doc écrit
# docs/services.md à partir d'ici. Ne pas éditer docs/services.md.
# ===================================================================

REGS = ['A', 'B', 'E', 'F', 'X', 'Y', 'U', 'DP']

ABSENT = 'ABSENT'
TOUCHE_A = [0x15, 0xF0, 0x15]               # PS/2 : « a » en AZERTY, appuyé, relâché
ENTREE = [0x5A, 0xF0, 0x5A]
PARTITION = bytes([0x03, 0xE8, 0x03, 0xE8, 0x02, 0xFF, 0xFF])


def _sym(nom, plus=0):
    return lambda m: m.s_[nom] + plus


def _appel(sym, **regs):
    """Préparation : appelle d'abord un autre service (par son adresse)."""
    def f(m):
        import verifie_fs as v
        for r, val in regs.items():
            setattr(m, r, val)
        m.s = 0xDF00
        v.appelle(m, m.s_[sym])
    return f


def _absent(num, nom, sys, note):
    return dict(num=num, nom=nom, sys=sys, entree='-', sortie='C = 1', sortie_regs=[],
                detruit=[], note=note, scenarios=[dict(nom='retiré', c=1)])


CONTRAT = [
    dict(num=0, nom='FS_RenameFile', sys='FS_RenameFile',
         entree='X -> ancien nom, Y -> nouveau nom (15 octets, `Format_Filename_83`)',
         sortie='C',
         sortie_regs=[], detruit=['E', 'F'],
         note='BIOS2. Le nouveau nom donne le dossier d\'arrivée (`"LIB/UI.INC"` déplace ; '
              '`"LIB/"` garde le nom). Refuse un nom pris et un dossier mis dans lui-même.',
         scenarios=[dict(nom='renomme', regs={'X': ('nom', 'ANCIEN'), 'Y': ('nom2', 'NOUVEAU')}, c=0),
                    dict(nom='absent', regs={'X': ('nom', ABSENT), 'Y': ('nom2', 'NOUVEAU')}, c=1)]),
    dict(num=1, nom='scan_keyboard', sys='scan_keyboard',
         entree='-', sortie='A = caractère (jamais 0)', sortie_regs=['A'], detruit=['B'],
         note='Attend une touche (rendue au relâchement). Jette une file déjà lue par un '
              'programme qui lit `SCAN_CODE` lui-même. Codes spéciaux `$80-$8B` : `lib/ui.inc`.',
         scenarios=[dict(nom='a', touches=TOUCHE_A, verif={'A': 0x61})]),
    dict(num=2, nom='read_line', sys='read_line',
         entree='-', sortie='`input_buffer` = la ligne (NUL final), X = sa fin',
         sortie_regs=['X'], detruit=['A', 'B'],
         note='Attend Entrée ; écho à l\'écran ; Ret. arr. efface.',
         scenarios=[dict(nom='a + Entrée', touches=TOUCHE_A + ENTREE)]),
    dict(num=3, nom='PrintChar', sys='PrintChar',
         entree='A = caractère', sortie='-', sortie_regs=[], detruit=[],
         note='Écran seulement (jamais la liaison série), attribut `char_attribut`. '
              '`$0C` efface, `$09` tabule. Attend si le tampon de 256 est plein.',
         scenarios=[dict(nom='Z', regs={'A': 0x5A})]),
    dict(num=4, nom='PrintString', sys='PrintString',
         entree='X -> chaîne (NUL final)', sortie='-', sortie_regs=[], detruit=[],
         note='',
         scenarios=[dict(nom='Bonjour', regs={'X': ('chaine', 'Bonjour')})]),
    dict(num=5, nom='PrintHexChar', sys='PrintHexChar',
         entree='A = octet', sortie='-', sortie_regs=[], detruit=['A'],
         note='Deux chiffres hexadécimaux. A n\'est PAS rendu (il reste son chiffre bas).',
         scenarios=[dict(nom='$3C', regs={'A': 0x3C})]),
    dict(num=6, nom='PrintHexWord', sys='PrintHexWord',
         entree='D = mot', sortie='-', sortie_regs=[], detruit=[],
         note='Quatre chiffres.',
         scenarios=[dict(nom='$12AB', regs={'A': 0x12, 'B': 0xAB})]),
    dict(num=7, nom='PrintCRLF', sys='PrintCRLF',
         entree='-', sortie='-', sortie_regs=[], detruit=[],
         note='LF puis CR.',
         scenarios=[dict(nom='')]),
    _absent(8, 'PrintFileName83', 'PrintFileName83', 'Retiré (moniteur).'),
    dict(num=9, nom='FS_Mount', sys='FS_Mount',
         entree='-', sortie='A = 0', sortie_regs=['A'], detruit=[],
         note='Pas de superbloc : remet l\'état de lecture à zéro. Le BIOS l\'a déjà fait au démarrage.',
         scenarios=[dict(nom='')]),
    dict(num=10, nom='FS_FindFirst', sys='FS_FindFirst',
         entree='-', sortie='C = 0 : `g_find_fileInfo` = la première entrée du dossier courant',
         sortie_regs=[], detruit=['E', 'F', 'Y'],
         note='Puis `FS_FindNext`. `g_find_fileInfo+30` = numéro de l\'entrée + 1.',
         scenarios=[dict(nom='', c=0)]),
    dict(num=11, nom='FS_FindNext', sys='FS_FindNext',
         entree='-', sortie='C = 0 : entrée suivante dans `g_find_fileInfo` ; C = 1 : fin',
         sortie_regs=[], detruit=['E', 'F'],
         note='',
         scenarios=[dict(nom='après FindFirst', prep=_appel('FS_FindFirst'), c=0)]),
    _absent(12, 'FS_GetNextCluster', 'FS_GetNextCluster', 'Sans objet (fichiers contigus).'),
    dict(num=13, nom='FS_LoadFile', sys='FS_LoadFile',
         entree='X -> nom (15), A = page, Y = adresse',
         sortie='C ; U = taille (16 bits bas)', sortie_regs=['U'], detruit=['E', 'F'],
         note='Continue en `$0000` de la page suivante après `$7FFF` (64 Ko, page 3 au plus). '
              'Y >= `$8000` : copie directe. Nom sans chemin introuvable : réessaie dans /BIN, '
              'puis à la racine. La page de l\'appelant revient.',
         scenarios=[dict(nom='TEXTE -> 1:$4000', regs={'X': ('nom', 'TEXTE'), 'A': 1, 'Y': 0x4000},
                         c=0, verif={'U': 515}),
                    dict(nom='absent', regs={'X': ('nom', ABSENT), 'A': 1, 'Y': 0x4000}, c=1)]),
    dict(num=14, nom='FS_FindEntry', sys='FS_FindEntry',
         entree='X -> nom (15)',
         sortie='C ; D = premier secteur (16 bits bas), U = taille (16 bits bas)',
         sortie_regs=['A', 'B', 'U'], detruit=['E', 'F'],
         note='Repli /BIN puis racine comme `FS_LoadFile`. `s_entry_lba`/`s_entry_offset` = l\'entrée.',
         scenarios=[dict(nom='TEXTE', regs={'X': ('nom', 'TEXTE')}, c=0, verif={'U': 515}),
                    dict(nom='absent', regs={'X': ('nom', ABSENT)}, c=1)]),
    dict(num=15, nom='FS_ListRoot', sys='FS_ListRoot',
         entree='-', sortie='A = 0', sortie_regs=['A'], detruit=['E', 'F'],
         note='BIOS2. Affiche le dossier courant.',
         scenarios=[dict(nom='')]),
    dict(num=16, nom='FS_SaveFile', sys='FS_SaveFile',
         entree='X -> nom (15), A = page source, Y = source, U = taille',
         sortie='C', sortie_regs=[], detruit=['E', 'F'],
         note='BIOS2. Crée TOUJOURS une nouvelle entrée : effacer l\'ancien fichier d\'abord. '
              'Source sur deux pages comme `FS_LoadFile`.',
         scenarios=[dict(nom='100 octets', regs={'X': ('nom', 'NOUVEAU'), 'A': 0, 'Y': 0x4000, 'U': 100}, c=0),
                    dict(nom='page 4 refusée', regs={'X': ('nom', 'NOUVEAU'), 'A': 4, 'Y': 0x4000, 'U': 100}, c=1)]),
    _absent(17, 'reg_cmd', 'reg_cmd', 'Retiré (moniteur ; `MONITEUR R` sur la carte).'),
    _absent(18, 'FS_ClusterToLBA_Offset', 'FS_ClusterToLBA_Offset', 'Sans objet (fichiers contigus).'),
    dict(num=19, nom='Format_Filename_83', sys='Format_Filename_83',
         entree='X -> nom ou chemin (NUL final), Y -> tampon de 16 octets',
         sortie='tampon = dernier composant, majuscules, complété de blancs (15)',
         sortie_regs=[], detruit=['E', 'F'],
         note='Avec un `/` (`../LIB/UI.INC`, `/APPS/X`) : les dossiers sont résolus et retenus '
              'pour ce tampon (4 au plus, `fs_slots`) ; dossier introuvable : les `FS_*` échoueront. '
              'À appeler avant tout `FS_*` qui prend un nom. La retenue ne signifie rien.',
         scenarios=[dict(nom='texte', regs={'X': ('chaine', 'texte'), 'Y': ('tampon', 0)}),
                    dict(nom='/DOSS/X', regs={'X': ('chaine', '/DOSS/X'), 'Y': ('tampon', 0)}),
                    dict(nom='/NUL/X', regs={'X': ('chaine', '/NUL/X'), 'Y': ('tampon', 0)})]),
    dict(num=20, nom='strcpy', sys='strcpy',
         entree='X -> source, Y -> destination (NUL final copié)', sortie='-',
         sortie_regs=[], detruit=[], note='',
         scenarios=[dict(nom='', regs={'X': ('chaine', 'copie'), 'Y': ('tampon', 0)})]),
    dict(num=21, nom='strlen', sys='strlen',
         entree='X -> chaîne', sortie='D = longueur', sortie_regs=['A', 'B'], detruit=[],
         note='',
         scenarios=[dict(nom='Bonjour', regs={'X': ('chaine', 'Bonjour')}, verif={'A': 0, 'B': 7})]),
    dict(num=22, nom='Pager', sys='pager',
         entree='A = page', sortie='la page A est visible en `$0000-$7FFF`',
         sortie_regs=[], detruit=[],
         note='Ne vérifie rien (page > 3 : adresse inconnue). Le code qui l\'appelle doit être hors '
              'de la page qu\'il quitte (RAM système, EPROM).',
         scenarios=[dict(nom='page 1', regs={'A': 1}, change_page=True)]),
    dict(num=23, nom='LoadandExec', sys='loadandexec',
         entree='X -> nom (15), A = page, Y = adresse',
         sortie='C', sortie_regs=[], detruit=['E', 'F', 'U'],
         note='Charge, appelle en Y (JSR), puis remet la page 0 : pour un appelant de la page 0. '
              'Les registres au retour sont ceux de l\'entrée, pas ceux du programme.',
         scenarios=[dict(nom='PROG', regs={'X': ('nom', 'PROG'), 'A': 1, 'Y': 0x1000}, c=0),
                    dict(nom='absent', regs={'X': ('nom', ABSENT), 'A': 1, 'Y': 0x1000}, c=1)]),
    _absent(24, 'ls_cmd', 'ls', 'Retiré (commande `LS` sur la carte).'),
    dict(num=25, nom='malloc_sys', sys='malloc_sys',
         entree='D = taille', sortie='X = bloc, ou 0 (plein)', sortie_regs=['X'], detruit=['Y'],
         note='Tas système de 256 octets (le SHELL). Pas de retenue.',
         scenarios=[dict(nom='16 octets', regs={'A': 0, 'B': 16})]),
    dict(num=26, nom='free', sys='free',
         entree='X = bloc (0 : rien)', sortie='-', sortie_regs=[], detruit=['X'],
         note='Pas de retenue.',
         scenarios=[dict(nom='X = 0', regs={'X': 0}),
                    dict(nom='bloc', regs={'X': _sym('__bss_end__', 3)})]),
    dict(num=27, nom='FS_DeleteFile', sys='FS_DeleteFile',
         entree='X -> nom (15)', sortie='C', sortie_regs=[], detruit=['E', 'F', 'U'],
         note='BIOS2. Refuse un dossier non vide.',
         scenarios=[dict(nom='VIEUX', regs={'X': ('nom', 'VIEUX')}, c=0),
                    dict(nom='absent', regs={'X': ('nom', ABSENT)}, c=1)]),
    dict(num=28, nom='FS_GetAttributes', sys='FS_GetAttributes',
         entree='X -> nom (15)', sortie='C ; A = attributs', sortie_regs=['A'], detruit=['E', 'F', 'U'],
         note='Bit 0 x, 1 w, 2 r, 3 caché, 4 application, 5 dossier.',
         scenarios=[dict(nom='TEXTE', regs={'X': ('nom', 'TEXTE')}, c=0, verif={'A': 0x07}),
                    dict(nom='absent', regs={'X': ('nom', ABSENT)}, c=1)]),
    dict(num=29, nom='FS_SetAttributes', sys='FS_SetAttributes',
         entree='X -> nom (15), A = attributs', sortie='C', sortie_regs=[], detruit=['E', 'F', 'U'],
         note='BIOS2.',
         scenarios=[dict(nom='TEXTE', regs={'X': ('nom', 'TEXTE'), 'A': 0x07}, c=0),
                    dict(nom='absent', regs={'X': ('nom', ABSENT), 'A': 0x07}, c=1)]),
    dict(num=30, nom='FarRead', sys='FarRead',
         entree='A = page source, B = page destination, X = source, Y = destination, U = taille',
         sortie='-', sortie_regs=[], detruit=[],
         note='Par blocs de 256 (`far_transit_buffer`), IRQ et FIRQ masquées pendant chaque bloc. '
              'À appeler sur la pile système si la pile du programme est dans une page.',
         scenarios=[dict(nom='2:$1000 -> 0:$4000', regs={'A': 2, 'B': 0, 'X': 0x1000, 'Y': 0x4000, 'U': 300})]),
    dict(num=31, nom='FarWrite', sys='FarWrite',
         entree='A = page destination, B = page source, X = source, Y = destination, U = taille',
         sortie='-', sortie_regs=[], detruit=[],
         note='Comme `FarRead`.',
         scenarios=[dict(nom='0:$4000 -> 2:$2000', regs={'A': 2, 'B': 0, 'X': 0x4000, 'Y': 0x2000, 'U': 300})]),
    dict(num=32, nom='video_wait_vsync', sys='video_wait_vsync',
         entree='E = nombre de trames', sortie='C = 0', sortie_regs=[], detruit=[],
         note='Les IRQ doivent être démasquées (le compteur avance dans l\'IRQ VSYNC).',
         scenarios=[dict(nom='2 trames', regs={'E': 2}, c=0)]),
    dict(num=33, nom='snd_play', sys='snd_play',
         entree='X -> partition (`FDB voix1,voix2 / FCB durée`..., `FDB $FFFF`)',
         sortie='-', sortie_regs=[], detruit=[],
         note='BIOS2. Copiée dans `SND_BUF` (128 octets) sauf si X >= `$C000`. Interrompt le son en cours. '
              'Format : `lib/snd.inc`.',
         scenarios=[dict(nom='', regs={'X': ('partition', PARTITION)})]),
    dict(num=34, nom='snd_stop', sys='snd_stop',
         entree='-', sortie='-', sortie_regs=[], detruit=[],
         note='BIOS2. Le silence vient à la trame suivante.',
         scenarios=[dict(nom='')]),
    dict(num=35, nom='Far_Call', sys='Far_Call',
         entree='A = page (0-3), X = adresse ; B, Y, U, W passés à l\'appelée',
         sortie='D, X, Y, U, W et C rendus par l\'appelée', sortie_regs=['A', 'B', 'E', 'F', 'X', 'Y', 'U'],
         detruit=[],
         note='L\'appelée reçoit A = sa page et doit fixer C elle-même (sinon C est quelconque). '
              'Page > 3 : C = 1, rien n\'est appelé. Aussi en `$FFE0`.',
         scenarios=[dict(nom='2:$1000 (RTS)', regs={'A': 2, 'X': 0x1000}, verif={'A': 2}),
                    dict(nom='page 4', regs={'A': 4, 'X': 0x1000}, c=1)]),
    dict(num=36, nom='Far_CallN', sys='Far_CallN',
         entree='A = page (0-3), B = n° dans la table `FDB` en `$0000` de la page',
         sortie='comme `Far_Call`', sortie_regs=['A', 'B', 'E', 'F', 'X', 'Y', 'U'], detruit=[],
         note='L\'appelée reçoit X = sa propre adresse. Aussi en `$FFE3`.',
         scenarios=[dict(nom='2, fonction 0', regs={'A': 2, 'B': 0}),
                    dict(nom='page 4', regs={'A': 4, 'B': 0}, c=1)]),
    dict(num=37, nom='FS_FileInfo', sys='FS_FileInfo',
         entree='X -> nom (15), Y -> 14 octets', sortie='C ; les octets +16..+29 de l\'entrée en Y',
         sortie_regs=[], detruit=['E', 'F'],
         note='Premier LBA (4), taille (4), page, adresse (2), attributs, dossier parent (2) ; '
              'tous en big-endian. Pas de repli /BIN.',
         scenarios=[dict(nom='TEXTE', regs={'X': ('nom', 'TEXTE'), 'Y': ('tampon', 0)}, c=0),
                    dict(nom='absent', regs={'X': ('nom', ABSENT), 'Y': ('tampon', 0)}, c=1)]),
    dict(num=38, nom='FS_ReadSector', sys='FS_ReadSector',
         entree='X -> LBA (4 octets BE), Y -> 512 octets', sortie='C (`sd_err`)',
         sortie_regs=[], detruit=[],
         note='Dans la page visible ou la RAM système. 4 essais.',
         scenarios=[dict(nom='LBA 1', regs={'X': ('lba', 1), 'Y': ('tampon', 0)}, c=0)]),
    dict(num=39, nom='FS_SetLoad', sys='FS_SetLoad',
         entree='X -> nom (15), A = page, Y = adresse', sortie='C', sortie_regs=[], detruit=['E', 'F'],
         note='BIOS2. Page et adresse de chargement de l\'entrée.',
         scenarios=[dict(nom='TEXTE', regs={'X': ('nom', 'TEXTE'), 'A': 1, 'Y': 0x2000}, c=0),
                    dict(nom='absent', regs={'X': ('nom', ABSENT), 'A': 1, 'Y': 0x2000}, c=1)]),
    dict(num=40, nom='FS_ChDir', sys='FS_ChDir',
         entree='X -> chemin (NUL final) : `APPS`, `..`, `/`, `/APPS/JEUX`', sortie='C',
         sortie_regs=[], detruit=['E', 'F'],
         note='Échec : dossier courant inchangé. Le dossier courant est commun à tous les programmes.',
         scenarios=[dict(nom='DOSS', regs={'X': ('chaine', 'DOSS')}, c=0),
                    dict(nom='NUL', regs={'X': ('chaine', 'NUL')}, c=1)]),
    dict(num=41, nom='FS_MkDir', sys='FS_MkDir',
         entree='X -> nom (15, `Format_Filename_83`)', sortie='C', sortie_regs=[], detruit=['E', 'F'],
         note='BIOS2. Refuse un nom pris.',
         scenarios=[dict(nom='NOUVDOSS', regs={'X': ('nom', 'NOUVDOSS')}, c=0),
                    dict(nom='DOSS existe', regs={'X': ('nom', 'DOSS')}, c=1)]),
    dict(num=42, nom='FS_Dossier', sys='FS_Dossier',
         entree='D = n° de dossier (0 racine), ou `$FFFF` pour lire', sortie='D = dossier courant',
         sortie_regs=['A', 'B'], detruit=[],
         note='Le n° est celui de `g_find_fileInfo+30` après `FS_FindNext`.',
         scenarios=[dict(nom='lire', regs={'A': 0xFF, 'B': 0xFF}, verif={'A': 0, 'B': 0})]),
    dict(num=43, nom='FS_DirInfo', sys='FS_DirInfo',
         entree='D = n° de dossier (pas 0), Y -> 15 octets ou 0', sortie='C ; D = son parent, son nom en Y',
         sortie_regs=['A', 'B'], detruit=['E', 'F'],
         note='C = 1 : pas un dossier.',
         scenarios=[dict(nom='DOSS', regs={'A': 0, 'B': 5, 'Y': ('tampon', 0)}, c=0),
                    dict(nom='TEXTE', regs={'A': 0, 'B': 1, 'Y': ('tampon', 0)}, c=1)]),
    dict(num=44, nom='kbd_poll', sys='kbd_poll',
         entree='-', sortie='A = caractère, ou 0 : rien', sortie_regs=['A'], detruit=['B'],
         note='Sans attendre ; à appeler à chaque trame au moins (file de 16 octets).',
         scenarios=[dict(nom='rien', verif={'A': 0}),
                    dict(nom='a', touches=TOUCHE_A, verif={'A': 0x61})]),
    dict(num=45, nom='Console_Zone', sys='Console_Zone',
         entree='A = colonne, B = rangée, E = largeur, F = hauteur, Y = attribut (octet bas) ; '
                'E = 0 : plein écran', sortie='C = 0', sortie_regs=[], detruit=[],
         note='BIOS2. La zone est effacée par l\'IRQ au fil des trames, le curseur va en haut à gauche.',
         scenarios=[dict(nom='2,3 20x5', regs={'A': 2, 'B': 3, 'E': 20, 'F': 5, 'Y': 0x1F}, c=0),
                    dict(nom='plein écran', regs={'E': 0}, c=0)]),
    dict(num=46, nom='(réserve)', sys='reserve', entree='-', sortie='C = 1', sortie_regs=[],
         detruit=[], note='Libre.', scenarios=[dict(nom='', c=1)]),
    dict(num=47, nom='(réserve)', sys='reserve', entree='-', sortie='C = 1', sortie_regs=[],
         detruit=[], note='Libre.', scenarios=[dict(nom='', c=1)]),
]


def doc():
    """Le texte de docs/services.md."""
    l = ['# Services du BIOS : le contrat', '',
         'Généré par `python3 test/verifie_contrat.py --doc` depuis `test/contrat_services.py` :',
         'ne pas éditer ici. Chaque ligne est mesurée sur le vrai BIOS par',
         '`make -C test contrat`.', '',
         'Appel : `JSR [table_function_ram+sys_XXX]` (`bios/sysfunc.inc`, `bios/hardware.inc`).',
         'Retenue : quand la sortie dit C, C = 1 échec et C = 0 réussite ; sinon elle ne signifie rien.',
         'Un registre qui n\'est ni une sortie ni',
         '« détruit » est rendu tel quel (A B E F X Y U, DP et la pile) ; les autres bits de',
         'CC ne sont pas garantis. Les noms de fichier sont de 15 octets, mis en forme par',
         '`Format_Filename_83`. « BIOS2 » : sans `/BIN/BIOS2`, le service rend C = 1.', '',
         '| n° | Service | Entrée | Sortie | Détruit | Notes |', '|---:|---|---|---|---|---|']
    for c in CONTRAT:
        det = ' '.join(c['detruit']) or '-'
        nom = '`%s`' % c['nom'] if not c['nom'].startswith('(') else c['nom']
        l.append('| %d | %s | %s | %s | %s | %s |' % (c['num'], nom, c['entree'], c['sortie'], det, c['note']))
    l.append('')
    return '\n'.join(l)


def ecrit_doc(chemin):
    open(chemin, 'w', encoding='utf-8').write(doc())
    print('%s : %d services' % (chemin, len(CONTRAT)))
