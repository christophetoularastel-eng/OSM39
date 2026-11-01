# ===================================================================
# Makefile racine pour le projet OSM09V7
# ===================================================================

.PHONY: all clean

all:
	$(MAKE) -C bios
	$(MAKE) -C shell
	$(MAKE) -C forth
	$(MAKE) -C cmd
	$(MAKE) -C asm
	$(MAKE) -C osmvision

clean:
	$(MAKE) -C bios clean
	$(MAKE) -C shell clean
	$(MAKE) -C forth clean
	$(MAKE) -C cmd clean
	$(MAKE) -C asm clean
	$(MAKE) -C osmvision clean
