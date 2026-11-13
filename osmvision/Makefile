# ===================================================================
# Makefile DÉFINITIF V2 pour le projet OSM09
# ===================================================================

AS = lwasm
LD = lwlink
OBJCOPY = objcopy

# Fichier binaire final, prêt à être gravé
TARGET_EXE = OSMVISION

SOURCES = osmvision.asm
OBJECTS = $(SOURCES:.asm=.o)

# --- SONDE : banc d'ecran livre par fload, pas par LOAD+RUN 0000 ----
# Meme algorithme que test/stage1_bandes (valide a l'oeil sur la carte),
# ZERO appel BIOS, mais charge depuis la carte SD. Elle isole donc la
# SEULE variable qui n'ait pas ete eliminee : le banc est lance par
# LOAD + RUN 0000, OSMVISION par fload (sys_pager + FS_LoadFile).
SONDE_EXE = SONDE
SONDE_OBJ = sonde.o

ASFLAGS = --format=obj --6309

# --- Options pour l'éditeur de liens (LDFLAGS) ---
#
# ⚠ NE PAS REMETTRE `--section-base=.code=0x0000`.
#
# Avec cette option, lwlink place AUSSI `.bss` a $0000, PAR-DESSUS
# `.code` :
#       Section: .code  load at 0000, length 029F
#       Section: .bss   load at 0000, length 0012
#       Symbol: FileCount = 0000     Symbol: Vision_Start = 0000
# `CLR FileCount` ecrivait donc sur le premier octet du point d'entree,
# et `STA Selection` / la copie des noms ecrivaient sur le code lui-meme.
#
# C'est mesure, pas suppose : les trois options ont ete essayees.
#   --section-base=.code=0x0000                          -> .bss a 0000  (x)
#   --section-base=.code=0x0000 --section-base=.bss=0x7000 -> .bss a 0000 (x)
#   (aucune)                                              -> .bss a 029F  (ok)
# Le defaut de lwlink fait deja ce qu'il faut : `.code` a $0000 et
# `.bss` juste apres, a l'adresse de fin de code.
LDFLAGS = --format=raw --map=$(TARGET_EXE).map



# Fichiers cibles
TARGET_EXE = OSMVISION
TARGET_HEX = osmvision.hex

# La règle par défaut : on veut le binaire ET le hex
all: $(TARGET_EXE) $(TARGET_HEX)

# Étape 1 : Lier les objets pour créer le fichier binaire (raw)
$(TARGET_EXE): $(OBJECTS)
	@echo "Édition des liens vers le format bin..."
	$(LD) $(LDFLAGS) -o $@ $^

# Étape 2 : Convertir le binaire en .hex (Intel Hex)
$(TARGET_HEX): $(TARGET_EXE)
	@echo "Conversion en format HEX..."
	$(OBJCOPY) -I binary -O ihex $(TARGET_EXE) $@


# Règle générique pour assembler les .asm en .o (version mise à jour)
%.o: %.asm ../bios/hardware.inc ../bios/sysfunc.inc ../lib/ui.inc ../lib/vis.inc ../lib/vision.asm ../lib/latin_cp437.inc ../lib/clouris.asm ../lib/snd.inc ../lib/snd.asm ../lib/str.asm ../lib/vram.asm
	@echo "Assemblage de $<..."
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<
	@# GARDE-FOU : Vision_Start a $$0000 (BOOT y saute). Les applications
	@# n'appellent plus OSM-VISION (elles tournent dans leur page, avec leur
	@# copie de lib/vision.asm) : plus de table a adresse fixe ici.
	@for s in Vision_Start:0000; do \
	   n=$${s%%:*}; want=$${s##*:}; \
	   off=$$(grep -oE "^[[:xdigit:]]{4} .*[[:space:]]$$n:" $*.lst | head -1 \
	          | grep -oE '^[[:xdigit:]]{4}'); \
	   if [ "$$off" != "$$want" ]; then \
	     echo "ERREUR : $$n est a l'offset '$$off', pas $$want." >&2; exit 1; \
	   fi; \
	 done; echo "  en-tete : Vision_Start 0000, OK"

# La sonde n'a PAS la meme dependance : elle n'appelle aucun service du
# BIOS, donc pas besoin de sysfunc.inc. Elle garde le --list pour que les
# octets soient relisibles, comme le reste du depot.
$(SONDE_OBJ): sonde.asm ../bios/hardware.inc
	@echo "Assemblage de sonde.asm (SONDE)..."
	$(AS) $(ASFLAGS) --list=sonde.lst -o $@ $<
	@# GARDE-FOU : `start` DOIT etre a l'offset 0000. fload fait
	@# `JSR 0,Y` sur l'adresse de boot de l'entree (qui est 0). Si un
	@# `include` se glisse avant `start`, la machine demarre au milieu
	@# d'une routine -- exactement le symptome "rien ne se passe".
	@off=$$(grep -oE '^[[:xdigit:]]{4} .*start:' sonde.lst | head -1 \
	       | grep -oE '^[[:xdigit:]]{4}'); \
	 if [ "$$off" != "0000" ]; then \
	   echo "ERREUR : start est a l'offset '$$off', pas 0000." >&2; exit 1; \
	 else \
	   echo "  start : offset 0000, OK"; \
	 fi

$(SONDE_EXE): $(SONDE_OBJ)
	@echo "Édition des liens de SONDE..."
	$(LD) --format=raw --section-base=.code=0x0000 -o $@ $<
	@echo "  SONDE   = $$(stat -c%s $@) octets a SAVE sur la carte"

sonde: $(SONDE_EXE)

# Nettoyage (on ajoute .srec)
clean:
	@echo "Nettoyage du projet..."
	rm -f $(OBJECTS) $(SONDE_OBJ) *.map OSMVISION OSMVISION.EXE osmvision.hex $(SONDE_EXE)

.PHONY: all clean sonde
