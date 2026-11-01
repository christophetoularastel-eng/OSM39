#!/usr/bin/env python3
# ===================================================================
# test/verifie_rendu.py - preuve independante que splash_draw ecrit
# chaque caractere au bon offset de la fenetre video.
# -------------------------------------------------------------------
# Le principe : ne faire confiance ni au source, ni a l'emulateur.
#
#   1. La table est relue DANS LE BINAIRE emis, a l'adresse que le
#      binaire contient reellement.
#   2. Chaque instruction de splash_draw est decodee sur les OCTETS
#      EMIS, puis CONFRONTEE a sa ligne de source dans le listing.
#      Si le source change et qu'un octet change de sens, l'etape 2
#      echoue au lieu de continuer a appliquer une regle qui n'a plus
#      de sens. C'est ce controle-la qui rend credible le reste.
#   3. Chaque ecriture video est capturee, puis comparee a une formule
#      ecrite separement. Une formule recopiant le code ne prouverait
#      rien : les deux chemins sont independants.
#
# Les formes non couvertes ici ne sont pas "ignorees" : elles font
# echouer le script. Un emulateur qui ignore ce qu'il ne connait pas
# est un emulateur qui ment.
#
# CARTE V4 (10 oct. 2026) : le PLAN est decide par l'ADRESSE, et non
# plus par la derniere valeur ecrite dans VRAM_CTRL ($A120). U126 prend
# a12 : caracteres en $8000-$8FFF, couleurs en $9000-$9FFF (meme
# cellule + $1000). VRAM_CTRL ne porte plus que la page (D0-D2) ; D3
# (« RAM couleurs », l'ancien $08) et D4 (« mode affichage », l'ancien
# $10) sont ignores par la carte. Le modele route donc chaque ecriture
# selon son adresse, et exige seulement que la page 0 soit choisie
# ($00) avant la premiere ecriture video.
#
# Usage: cd test && make STAGE=stage3_splash all
#        (le Makefile passe le listing de l'etape, puis le nom de la
#        table a rendre, en arguments)
# ===================================================================
import re
import sys

TEST = open("TEST", "rb").read()
LST = open(sys.argv[1] if len(sys.argv) > 1 else "stage3_splash.lst").read()

# [0-9A-Fa-f] et NON [0-9a-f] : la classe minuscule seule ne matche
# pas les offsets lwasm qui contiennent des majuscules (008B, 00EF...).
def label(nom):
    m = re.search(r"^([0-9A-Fa-f]{4})\s.*\b%s:" % nom, LST, re.M)
    if not m:
        sys.exit("label %s introuvable dans le listing" % nom)
    return int(m.group(1), 16)

AD_DRAW = label("splash_draw")

# -------------------------------------------------------------------
# LE NOM DE LA TABLE EST UN ARGUMENT, PAS UNE CONVENTION
# -------------------------------------------------------------------
# Il etait ecrit en dur a `splash_data`. Ce nom n'est pas une regle du
# banc : c'etait un contournement. Etape 2 etape 5 ont chacune LEUR
# table, et ne voulaient pas renommer `splash_data` -- d'ou un
# "Multiply defined symbol" a l'assemblage, parce que splash.asm
# declare aussi le splash de reference.
#
# La seule facon honnete est de demander la table plutot que de la
# deviner. `splash_draw` ne connait que deux choses : un pointeur et
# un format. Quel pointeur lui passe-t-on est l'appelant's affaire.
# Le defaut par defaut reste `splash_data`, qui est le nom du splash
# de reference -- mais le script ne suppose plus que ce soit LE nom.
TABLE = sys.argv[2] if len(sys.argv) > 2 else "splash_data"
AD_DATA = label(TABLE)

# -------------------------------------------------------------------
# 1. le listing : adresse -> (source, octets)
# -------------------------------------------------------------------
# formats vus :
#   "  0091 EEA0             (       common.inc):00201   ldu  ,y+"
#   "  00A1 3D               (       common.inc):00210   mul"
#   "  008B                  (       common.inc):00194   splash_draw:"
LIGNE = re.compile(
    r"^\s*([0-9A-Fa-f]{4})\s+((?:[0-9A-Fa-f]{2})+)?"          # offset + octets
    r"\s*\([^\)]*\):[0-9]+\s+(\S.*?)\s*$")

listing = {}
for ligne in LST.splitlines():
    m = LIGNE.match(ligne)
    if not m:
        continue
    ad = int(m.group(1), 16)
    octets = m.group(2) or ""
    src = re.sub(r";.*$", "", m.group(3)).strip()            # sans le commentaire
    listing[ad] = (src, [int(o, 16) for o in octets])

if not listing:
    sys.exit("listing illisible : aucune ligne instruction trouvee")

# -------------------------------------------------------------------
# 2. table des formes reconnues : (opcode[, postbyte]) -> (nom, effet)
#    "effet" est une fonction qui modifie les variables globales.
# -------------------------------------------------------------------
def s8(v):
    return v - 256 if v > 127 else v

def imm16(a):
    return TEST[a] << 8 | TEST[a + 1]

S = []                       # pile plate : see PSHS/PULS
A = B = D = X = Y = U = 0
Z = False
vcar = {}                    # offset dans la RAM caracteres -> caractere
vatt = {}                    # offset dans la RAM couleurs   -> attribut
ctrl = []                    # (valeur, nb d'ecritures video avant elle)
nwrite = 0

# Carte V4 : deux RAM a deux adresses. a12 choisit le plan.
CAR_BASE, CAR_FIN = 0x8000, 0x9000      # VRAM_BASE .. VRAM_END
COL_BASE, COL_FIN = 0x9000, 0xA000      # VRAM_COL  .. VRAM_COL_END
COL_OFS = COL_BASE - CAR_BASE           # VRAM_COL_OFS = $1000

def getD():
    return (A << 8) | B

def fenetre(u, quoi, val):
    """Une ecriture video. Le PLAN se lit dans l'ADRESSE (carte V4) :
    $8000-$8FFF -> caracteres, $9000-$9FFF -> couleurs. Tout le reste
    est hors fenetre -- en particulier $A000 et au-dela, l'ACIA RS232
    et le latch, que la RAM couleurs touche desormais."""
    global nwrite
    if CAR_BASE <= u < CAR_FIN:
        vcar[u - CAR_BASE] = val
    elif COL_BASE <= u < COL_FIN:
        vatt[u - COL_BASE] = val
    else:
        sys.exit("!! %s hors fenetre video : $%04X (attendu $%04X-$%04X)"
                 "\n   contexte :\n%s"
                 % (quoi, u, CAR_BASE, COL_FIN - 1,
                    "".join("     $%04X  %-22s D=%04X X=%04X Y=%04X U=%04X\n"
                            % t for t in trace)))
    nwrite += 1

def do_pshs(src):
    """pilote par le TEXTE DE LA SOURCE : le postbyte 6309 natif
    n'est pas decode ici, on ne veut pas deviner sa numerotation."""
    m = re.match(r"pshs\s+([\w,]+)$", src)
    if not m:
        sys.exit("pshs non reconnu : %r" % src)
    for r in m.group(1).split(","):
        if   r == "a":  S.append(A)
        elif r == "b":  S.append(B)
        elif r == "d":  S.append(getD())
        elif r == "x":  S.append(X)
        elif r == "y":  S.append(Y)
        elif r == "u":  S.append(U)
        elif r in ("cc", "dp"):
            S.append(0)                # les drapeaux ne nous interessent pas
        else:
            sys.exit("pshs registre inconnu : %r" % r)

def do_puls(src):
    global A, B, X, Y, U
    m = re.match(r"puls\s+([\w,]+)$", src)
    if not m:
        sys.exit("puls non reconnu : %r" % src)
    registres = m.group(1).split(",")
    for r in reversed(registres):     # PULS restaure en sens inverse
        v = S.pop() if S else sys.exit("pile vide")
        if   r == "a":  A = v & 0xFF
        elif r == "b":  B = v & 0xFF
        elif r == "d":  setD(v)
        elif r == "x":  X = v
        elif r == "y":  Y = v
        elif r == "u":  U = v
        elif r in ("cc", "dp"):
            pass
        else:
            sys.exit("puls registre inconnu : %r" % r)

# (octet a l'offset pc) -> (nb d'octets a sauter apres, nom attendu dans
# le source, effet). Le decodage passe par le SOURCE, pas par une table
# de postbytes : on ne pretend pas connaitre la numerotation 6309, on
# verifie seulement que les octets correspondent bien a la ligne de
# source qu'on est en train d'executer.
def decode(pc):
    op = TEST[pc]
    src = listing.get(pc, ("", []))[0]
    if not src:
        sys.exit("!! $%04X (%02X) absent du listing : le code a change, "
                 "ce verificateur doit etre relu" % (pc, op))
    mn = src.split()[0].lower()

    def need(*noms):
        if mn not in noms:
            sys.exit("!! $%04X : attendu %s dans le source, trouve %r"
                     % (pc, "/".join(noms), src))

    # --- 2 octets, immediat 8 bits ---------------------------------
    if op in (0x86, 0xC6, 0xB6, 0xF6):
        imm = TEST[pc + 1]
        if op == 0x86: need("lda");   return 2, (lambda: seta(imm))
        if op == 0xC6: need("ldb");   return 2, (lambda: setb(imm))
        sys.exit("!! $%04X : opcode %02X non couvert" % (pc, op))

    # --- ORCC : n'affecte ni les registres ni les drapeaux testes ---
    if op == 0x1A:
        need("orcc")
        return 2, (lambda: None)

    # --- PSHS / PULS : pilote par le source -------------------------
    if op == 0x34:
        need("pshs"); return 2, (lambda: do_pshs(src))
    if op == 0x35:
        need("puls"); return 2, (lambda: do_puls(src))

    # --- branche relative ------------------------------------------
    if op in (0x20, 0x27, 0x26):
        off = s8(TEST[pc + 1])
        if   op == 0x20: need("bra"); return 2, (lambda: branche(pc, off, True))
        elif op == 0x27: need("beq"); return 2, (lambda: branche(pc, off, Z))
        else:            need("bne"); return 2, (lambda: branche(pc, off, not Z))
    if op == 0x39:
        need("rts"); return 1, (lambda: sys.exit("__RTS__"))

    # --- indexe : le postbyte est verifie contre le source ----------
    if op in (0xA6, 0xE6, 0xA7, 0xE7, 0xEE, 0x31, 0x33):
        pb = TEST[pc + 1]
        entree = INDEXE.get((op, pb))
        if entree is None:
            sys.exit("!! $%04X : forme indexee non couverte "
                     "(op=%02X pb=%02X), source %r\n"
                     "   Si le code a change, ce verificateur doit etre "
                     "relu : ne le complete pas a l'aveugle." % (pc, op, pb, src))
        att, want, long_, ext = entree
        if want not in src:
            sys.exit("!! $%04X : octets (op=%02X pb=%02X) ne correspondent "
                     "pas au source %r" % (pc, op, pb, src))
        # Offset 16 bits (postbyte $C9 pour ,U) : les deux octets qui
        # suivent sont l'offset, relu DANS LE BINAIRE et confronte a la
        # valeur que le modele suppose. Un `stb VRAM_COL_OFS,u` dont la
        # constante changerait ne passerait donc pas en silence.
        if ext is not None and imm16(pc + 2) != ext:
            sys.exit("!! $%04X : offset emis $%04X, le modele suppose $%04X "
                     "pour %r" % (pc, imm16(pc + 2), ext, src))
        return long_, att

    # --- 3 octets, immediat 16 bits / etendu ------------------------
    if op in (0xCC, 0x8E, 0xCE, 0xFC):
        v = imm16(pc + 1)
        if op == 0xCC: need("ldd"); return 3, (lambda: setD(v))
        if op == 0x8E: need("ldx"); return 3, (lambda: setX(v))
        if op == 0xCE: need("ldu"); return 3, (lambda: setU(v))
        sys.exit("!! $%04X : opcode %02X non couvert" % (pc, op))
    if op == 0xB7:
        need("sta"); return 3, (lambda: sta(imm16(pc + 1)))

    # --- TFR : le source dit quels registres, pas le postbyte ------
    if op == 0x1F:
        # Postbyte TFR : nibble HAUT = registre source, nibble BAS =
        # registre destination. Codes vus ici : D=0 X=1 Y=2 U=3
        # (`tfr x,y` = $12, `tfr d,u` = $03).
        m = re.match(r"tfr\s+([dxyu]),([dxyu])$", src)
        if not m:
            sys.exit("!! $%04X : TFR non reconnu, source %r" % (pc, src))
        reg, dst = m.group(1), m.group(2)
        codes = {"d": 0, "x": 1, "y": 2, "u": 3}
        attendu = codes[reg] << 4 | codes[dst]
        if TEST[pc + 1] != attendu:
            sys.exit("!! $%04X : postbyte TFR %02X ne correspond pas a %r "
                     "(attendu $%02X)" % (pc, TEST[pc + 1], src, attendu))
        return 2, (lambda: tfr(dst, reg))

    # --- prefixe 6309 ----------------------------------------------
    if op == 0x11:
        return decode_11(pc)
    if op == 0x10:
        return decode_10(pc)

    # --- MUL --------------------------------------------------------
    if op == 0x3D:
        # `mul R` (registre) n'est PAS couvert : lwasm l'assemble en
        # MUL simple sans le dire, on ne peut donc pas distinguer les
        # deux depuis les octets. Le source permet de trancher.
        if re.match(r"mul\s+[xyus]$", src):
            sys.exit("!! $%04X : `mul %s` est un piege lwasm (operande "
                     "registre ignore). Utiliser `mul` avec B a 5."
                     % (pc, src.split()[1]))
        need("mul")
        return 1, (lambda: setD((getD() * B) & 0xFFFF))

    sys.exit("!! $%04X : opcode $%02X non couvert, source %r" % (pc, op, src))

# --- entrees/sorties de registres ----------------------------------
# ATTENTION : tout chargement de registre pose Z et N (le bit de
# parite est ignore, il n'est teste nulle part ici). L'oublier casse
# les `beq` de fin de segment : sans Z, `beq sd_seg_done` ne part
# jamais et le rendu deborde de la fenetre. C'est exactement ce qui
# est arrive au premier essai de ce verificateur.
def _nz(v, bits):
    global Z
    Z = (v & ((1 << bits) - 1)) == 0

def seta(v):
    global A
    A = v & 0xFF
    _nz(A, 8)

def setb(v):
    global B
    B = v & 0xFF
    _nz(B, 8)

def setD(v):
    global D, A, B
    D = v & 0xFFFF
    A = (D >> 8) & 0xFF
    B = D & 0xFF
    _nz(D, 16)

def setX(v):
    global X
    X = v & 0xFFFF
    _nz(X, 16)

def setY(v):
    global Y
    Y = v & 0xFFFF
    _nz(Y, 16)

def setU(v):
    global U
    U = v & 0xFFFF
    _nz(U, 16)

# --- LEA NE POSE PAS Z ------------------------------------------------
# Correction du 28 sept 2026, et c'est la meme erreur que celle de
# splash_bandes : le modele disait que `neau`/`leax` posaient Z, ce qui
# est FAUX. Une affectation d'adresse calcule un pointeur, elle ne
# compare rien. Le harm s'est vu parce que splash_draw ecrase le Z
# perime par un `lda ,y+` avant le `beq` : le bug etait la, et le
# modele le confirmait au lieu de le contredire.
#
# Un verificateur qui partage l'hypothese du code qu'il verifie ne
# peut pas trouver ce code faux. Les formes LEA passent donc par
# setU_sans_z / setX_sans_z, qui ne touchent a aucun drapeau.
def setU_sans_z(v):
    global U
    U = v & 0xFFFF

def setX_sans_z(v):
    global X
    X = v & 0xFFFF

def tfr(dst, src_reg):
    global A, B, D, X, Y, U
    g = {"a": A, "b": B, "d": getD(), "x": X, "y": Y, "u": U}
    v = g[src_reg]
    if dst == "d":   setD(v)
    elif dst == "a": seta(v)
    elif dst == "b": setb(v)
    elif dst == "x": setX(v)
    elif dst == "y": setY(v)
    elif dst == "u": setU(v)
    else: sys.exit("tfr registre inconnu %r" % dst)

def branche(pc, off, pris):
    global _pc
    _pc = (pc + 2 + off) & 0xFFFF if pris else (pc + 2)

def sta(ad):
    if ad == 0xA120:
        ctrl.append((A, nwrite))
    elif CAR_BASE <= ad < COL_FIN:
        fenetre(ad, "STA", A)
    else:
        sys.exit("!! STA sur une adresse etrangere : $%04X" % ad)

def addr(dst, src_reg):
    g = {"a": A, "b": B, "d": getD(), "x": X, "y": Y, "u": U}
    v = g[src_reg]
    if dst == "d":   setD(getD() + v)
    elif dst == "a": seta(A + v)
    elif dst == "b": setb(B + v)
    else: sys.exit("addr registre inconnu %r" % dst)

def decode_10(pc):
    sub = TEST[pc + 1]
    src = listing.get(pc, ("", []))[0]
    mn = src.split()[0].lower() if src else ""
    if sub == 0x48:                                  # LSLD
        if mn != "lsld":
            sys.exit("!! $%04X : 10 48 = LSLD, source %r" % (pc, src))
        return 2, (lambda: setD(getD() << 1))
    if sub == 0x30:                                  # ADDR r0,r1
        m = re.match(r"addr\s+([dxyus]),([dxyus])$", src)
        if not m:
            sys.exit("!! $%04X : ADDR non reconnu, source %r" % (pc, src))
        r0, r1 = m.group(1), m.group(2)
        if TEST[pc + 2] != POSTBYTE_REG.get(r0, -1):
            sys.exit("!! $%04X : postbyte ADDR ne correspond pas a %r"
                     % (pc, src))
        return 3, (lambda: addr(r1, r0))
    sys.exit("!! $%04X : forme 10 %02X non couverte, source %r"
             % (pc, sub, src))

def decode_11(pc):
    sub = TEST[pc + 1]
    src = listing.get(pc, ("", []))[0]
    mn = src.split()[0].lower() if src else ""
    if sub == 0x83:                                  # CMPU #imm16
        if mn != "cmpu":
            sys.exit("!! $%04X : 11 83 = CMPU #, source %r" % (pc, src))
        v = imm16(pc + 2)
        return 4, (lambda: setZ((U - v) & 0xFFFF == 0))
    sys.exit("!! $%04X : forme 11 %02X non couverte, source %r"
             % (pc, sub, src))

def setZ(v):
    global Z
    Z = v

# --- formes indexees reellement employees, avec leur source attendue.
#
#     Decodage par (opcode, postbyte), mais chaque entree porte la
#     ligne de source attendue : si le code change, le controle echoue
#     au lieu d'appliquer une regle devenue fausse.
#
#     Postbyte de la forme a offset 5 bits : $20 + offset, registre
#     dans les bits 2-0 (X=0, Y=1, U=2, S=3). Verifie ci-dessous par
#     l'auto-controle : `ldu 0,y` = $20, `ldu 2,y` = $22, `ldb 4,y`
#     = $24, `leay 5,y` = $25.
#
#     `,Y+` lit PUIS incremente : l'increment fait partie de l'effet,
#     l'oublier desalignerait toute la lecture de la table.
#
#     Volontairement AUCUNE entree pour un chargement 16 bits en
#     `,Y+` : en mode natif, `LDU ,Y+` consomme deux octets, et le
#     harnais ne pretendra pas savoir de combien avance Y. Si le code
#     en introduit une, ce script echoue bruyamment.
POSTBYTE_REG = {"d": 0x00, "x": 0x10, "y": 0x20, "u": 0x30, "s": 0x50}

INDEXE = {}
def _idx(op, pb, effet, attendu, long_=2, ext=None):
    """`long_` = longueur de l'instruction ; `ext` = offset 16 bits
    attendu dans les octets 2-3 (forme `n,R` a offset long), sinon None."""
    INDEXE[(op, pb)] = (effet, attendu, long_, ext)

def ldb_yplus():
    global Y
    setb(TEST[Y])
    Y = (Y + 1) & 0xFFFF

def lda_yplus():
    global Y
    seta(TEST[Y])
    Y = (Y + 1) & 0xFFFF

# `n,y` a offset 5 bits : les 16 bits pour LDU, 8 bits pour LDB/LEAY
_idx(0xEE, 0x20, lambda: setU(imm16(Y)),            "ldu     0,y")
_idx(0xEE, 0x22, lambda: setU(imm16(Y + 2)),        "ldu     2,y")
_idx(0xE6, 0x24, lambda: setb(TEST[Y + 4]),         "ldb     4,y")
_idx(0x31, 0x25, lambda: setY((Y + 5) & 0xFFFF),   "leay    5,y")

_idx(0xA6, 0xA0, lda_yplus, "lda     ,y+")
# Les ecritures ne disent PAS dans quel plan elles vont : c'est
# l'adresse qui le dit (carte V4), et `fenetre` qui la lit. `stb ,u`
# reste couvert alors que splash_draw ne l'emploie plus : c'est la
# forme V3 (attribut a la MEME adresse que le caractere), et elle doit
# produire un diagnostic de PLAN, pas « forme non couverte ».
_idx(0xA7, 0xC4, lambda: fenetre(U, "STA ,U", A),   "sta     ,u")
_idx(0xE7, 0xC4, lambda: fenetre(U, "STB ,U", B),   "stb     ,u")
_idx(0xE7, 0xC9, lambda: fenetre((U + COL_OFS) & 0xFFFF,
                                 "STB VRAM_COL_OFS,U", B),
     "stb     VRAM_COL_OFS,u", long_=4, ext=COL_OFS)
_idx(0x33, 0x41, lambda: setU_sans_z((U + 1) & 0xFFFF), "leau    1,u")


# -------------------------------------------------------------------
# 3. table du splash, relue dans le binaire
# -------------------------------------------------------------------
def lire_table(a):
    """Relit splash_data DEPUIS LE BINAIRE EMIS, dans le format de
    test/splash.asm : fdb ligne,colonne / fcb attribut / fcn "texte" /
    fdb $00FF,$0000 / fcb $00."""
    segs = []
    while True:
        if a + 5 > len(TEST):
            sys.exit("table non terminee a $%04X : il manque le "
                     "terminateur $00FF" % a)
        if imm16(a) == 0x00FF:
            return segs
        ligne, col = imm16(a), imm16(a + 2)
        attr = TEST[a + 4]
        a += 5
        s = b""
        while TEST[a]:
            s += bytes([TEST[a]])
            a += 1
        a += 1
        segs.append((ligne, col, attr, s))

segs = lire_table(AD_DATA)
if not segs:
    sys.exit("table vide : %s a $%04X n'est pas une table" % (TABLE, AD_DATA))
ncar = sum(len(s[3]) for s in segs)
print("  splash_draw  a $%04X, %s a $%04X" % (AD_DRAW, TABLE, AD_DATA))
print("  table lue dans le binaire : %d segments, %d caracteres"
      % (len(segs), ncar))
print("  lignes %d..%d, colonnes %d..%d"
      % (min(l for l, _, _, _ in segs), max(l for l, _, _, _ in segs),
         min(c for _, c, _, _ in segs), max(c for _, c, _, _ in segs)))

# --- attendu : formule ecrite a part, sans le code ---
attendu = {}
for ligne, col, attr, s in segs:
    for i, ch in enumerate(s):
        attendu[ligne * 80 + col + i] = (chr(ch), attr)

# -------------------------------------------------------------------
# 4. execution de splash_draw sur les octets emis
# -------------------------------------------------------------------
_pc = AD_DRAW
X = AD_DATA                 # splash_draw attend la table dans X
trace = []                  # 20 derniers pas, pour diagnostiquer

def contexte(n=20):
    return "".join("     $%04X  %-22s D=%04X X=%04X Y=%04X U=%04X\n"
                   % t for t in trace[-n:])

def executer():
    """`_pc` reste GLOBAL : `branche()` s'en sert pour-reduxner la
    pointe de lecture. La fonction ne fait qu'un pas de plus par
    tour, pour que le `except SystemExit` se rattache au bon bloc."""
    global _pc
    for _ in range(50000):
        # Garde-fou de depassement. Le +4 tolere la lecture legitime
        # du dernier mot de la table, apres quoi Y pointe sur la fin
        # du binaire. La borne de 50000 reste le vrai garde-fou
        # anti-boucle.
        if _pc >= len(TEST) or Y > len(TEST) + 4 or U > 0xFFFF:
            sys.exit("!! le rendu est sorti du binaire : PC=$%04X "
                     "Y=$%04X U=$%04X\n   derniers pas :\n%s"
                     % (_pc, Y, U, contexte()))
        trace.append((_pc, listing.get(_pc, ("?", []))[0],
                      getD(), X, Y, U))
        del trace[:-20]
        n, effet = decode(_pc)
        _pc += n
        try:
            effet()
        except IndexError:
            sys.exit("!! lecture hors du binaire a Y=$%04X "
                     "(taille $%04X)\n   contexte :\n%s"
                     % (Y, len(TEST), contexte()))

try:
    executer()
except SystemExit as e:
    if str(e) != "__RTS__":
        print(str(e))
        sys.exit(1)

# --- VRAM_CTRL, carte V4 -------------------------------------------
# Avant la V4, on exigeait un VRAM_CTRL final a $10 (D4 = 1, « mode
# affichage »). Ce mode n'existe plus : hors des acces du CPU, la VRAM
# est au 68B45. Ce qui reste a exiger : la PAGE. Le latch est en
# ecriture seule et le banc ne sait pas ce que le moniteur y a laisse,
# donc splash_draw doit choisir la page 0 AVANT sa premiere ecriture
# video, et n'y ecrire que $00 : une valeur avec D3-D5 (l'ancien $08 ou
# $10) trahit un code reste au schema V3, qui croit encore choisir un
# plan par le latch au lieu de l'adresse.
if not ctrl:
    sys.exit("!! VRAM_CTRL n'a jamais ete ecrit : la page video n'est pas "
             "choisie (le latch $A120 n'est pas relisible, le banc ne sait "
             "pas ce que le moniteur y a laisse)")
print("  simulation terminee : %d ecritures video, VRAM_CTRL ecrit %d fois"
      % (nwrite, len(ctrl)))
if ctrl[0][1] != 0:
    sys.exit("!! %d ecriture(s) video AVANT le premier VRAM_CTRL : la page "
             "n'etait pas encore choisie" % ctrl[0][1])
mauvais = [v for v, _ in ctrl if v != 0x00]
if mauvais:
    sys.exit("!! VRAM_CTRL recoit $%02X : la page doit etre 0 ($00). Carte "
             "V4 : seuls D0-D2 (page) comptent, D3 ne choisit plus la RAM "
             "couleurs (elle est en $9000-$9FFF) et D4 n'est plus un mode "
             "affichage" % mauvais[0])

# -------------------------------------------------------------------
# 5. confrontation
# -------------------------------------------------------------------
# D'abord le PLAN, en bloc : si AUCUN attribut n'a atteint la RAM
# couleurs, c'est que les attributs sont ecrits a l'adresse du
# caractere (schema V3 : meme adresse, plan choisi par $08 dans le
# latch). En V4 ils ecrasent alors les caracteres. Le dire d'une phrase
# vaut mieux que 2 x N ecarts caractere par caractere.
if attendu and not vatt:
    sys.exit("!! aucun attribut dans la RAM couleurs ($%04X-$%04X) : les "
             "attributs sont ecrits dans le plan caracteres. Carte V4 : "
             "couleur = adresse du caractere + $%04X (VRAM_COL_OFS)"
             % (COL_BASE, COL_FIN - 1, COL_OFS))

# Un octet attendu et jamais ecrit vaut None (absent du dict), pas 0 :
# distinguer les deux compte, sinon un `lda #$00` parasite passerait
# pour un espace. `_h()` affiche donc "jamais ecrit" plutot que de
# planter sur un %02X de None -- une traceback n'est pas un
# diagnostic, et le message doit rester lisible jusqu'au bout.
def _h(v):
    return "jamais ecrit" if v is None else "$%02X" % v


erreur = 0
rapporte = 0
PLAFOND = 12                       # au-dela, on resume le nombre
for off, (ch, attr) in sorted(attendu.items()):
    ecarts = []
    if vcar.get(off) != ord(ch):
        ecarts.append("attendu %r, obtenu %r" % (ch, vcar.get(off)))
    if vatt.get(off) != attr:
        ecarts.append("attribut attendu $%02X, obtenu %s"
                      % (attr, _h(vatt.get(off))))
    for quoi in ecarts:
        erreur += 1
        if rapporte < PLAFOND:
            print("  !! offset %4d (ligne %2d col %2d) : %s"
                  % (off, off // 80, off % 80, quoi))
        rapporte += 1
if erreur > rapporte:
    print("  !! ... et %d ecarts de plus non listes" % (erreur - rapporte))

en_trop = set(vcar) - set(attendu)
if en_trop:
    print("  !! %d caracteres ecrits hors de la table : %s"
          % (len(en_trop), sorted(en_trop)[:8]))
    erreur += len(en_trop)
en_trop = set(vatt) - set(attendu)
if en_trop:
    print("  !! %d attributs ecrits hors de la table : %s"
          % (len(en_trop), sorted(en_trop)[:8]))
    erreur += len(en_trop)

if erreur:
    sys.exit("ECHEC : %d ecarts" % erreur)
print("  OK : les %d caracteres et leurs attributs sont tous au bon"
      % len(attendu))
print("       offset (caracteres $8000-$8FFF, couleurs $9000-$9FFF), et")
print("       rien n'a ete ecrit hors de ces deux RAM ; page 0 choisie.")
