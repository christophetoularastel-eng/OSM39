# ===================================================================
# Makefile DÉFINITIF V2 pour le projet OSM09
# ===================================================================

AS = lwasm
LD = lwlink
OBJCOPY = objcopy

# Fichier binaire final, prêt à être gravé
TARGET_EXE = BRIQUES

SOURCES = briques.asm
OBJECTS = $(SOURCES:.asm=.o)


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
# BRIQUES tourne dans sa page (page 1, $0000), comme les applications : pas
# de --section-base du tout (voir ci-dessus), .bss juste après le code.
LDFLAGS = --format=raw --map=$(TARGET_EXE).map



# Fichiers cibles
TARGET_EXE = BRIQUES
TARGET_HEX = briques.hex

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
%.o: %.asm ../bios/hardware.inc ../bios/sysfunc.inc ../lib/ui.inc ../lib/vis.inc ../lib/vision.asm ../lib/vram.asm ../lib/snd.asm ../lib/snd.inc ../lib/ascii.asm ../lib/rowaddr.inc
	@echo "Assemblage de $<..."
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<

#
# Nettoyage (on ajoute .srec)
clean:
	@echo "Nettoyage du projet..."
	rm -f $(OBJECTS) $(SONDE_OBJ) *.map BRIQUES BRIQUES.EXE briques.hex
.PHONY: all clean sonde
