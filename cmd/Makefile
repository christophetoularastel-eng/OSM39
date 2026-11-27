# ===================================================================
# Makefile — Programmes externes OSM09 (TYPE, CP, MV, SIZE)
# ===================================================================

AS = lwasm
LD = lwlink
OBJCOPY = objcopy

ASFLAGS = --format=obj --6309 -I../bios
LDFLAGS = --format=raw --section-base=.code=0x0000

all: TYPE CP MV RM SIZE CPU CD MKDIR PWD LS MONITEUR SDTEST TELE AYTEST AYJOUE CLOUTEST JOYCAL HORLOGE NEIGE GRAPHE MORCEAUX

TYPE: type.asm type.o
	$(LD) $(LDFLAGS) --map=TYPE.map -o TYPE type.o
	$(OBJCOPY) -I binary -O ihex TYPE type.hex

CP: cp.asm cp.o
	$(LD) $(LDFLAGS) --map=CP.map -o CP cp.o
	$(OBJCOPY) -I binary -O ihex CP cp.hex

MV: mv.asm mv.o
	$(LD) $(LDFLAGS) --map=MV.map -o MV mv.o
	$(OBJCOPY) -I binary -O ihex MV mv.hex

RM: rm.asm rm.o
	$(LD) $(LDFLAGS) --map=RM.map -o RM rm.o
	$(OBJCOPY) -I binary -O ihex RM rm.hex

CD: cd.asm cd.o
	$(LD) $(LDFLAGS) --map=CD.map -o CD cd.o

MKDIR: mkdir.asm mkdir.o
	$(LD) $(LDFLAGS) --map=MKDIR.map -o MKDIR mkdir.o

PWD: pwd.asm pwd.o
	$(LD) $(LDFLAGS) --map=PWD.map -o PWD pwd.o

GRAPHE: graphe.asm graphe.o
	$(LD) $(LDFLAGS) --map=GRAPHE.map -o GRAPHE graphe.o

LS: ls.asm ls.o
	$(LD) $(LDFLAGS) --map=LS.map -o LS ls.o

MONITEUR: moniteur.asm moniteur.o
	$(LD) $(LDFLAGS) --map=MONITEUR.map -o MONITEUR moniteur.o

AYJOUE: ayjoue.asm ayjoue.o
	$(LD) $(LDFLAGS) --map=AYJOUE.map -o AYJOUE ayjoue.o

ayjoue.o: ayjoue.asm ../lib/ay_joue.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<

# Morceaux pour AYJOUE : ../tools/ay/morceaux/nom.txt -> NOM.MUS
MORCEAUX_TXT = $(wildcard ../tools/ay/morceaux/*.txt)
MORCEAUX: $(MORCEAUX_TXT:.txt=.MUS)

%.MUS: %.txt ../tools/ay/ay.py
	python3 ../tools/ay/ay.py $< -o $@

HORLOGE: horloge.asm horloge.o
	$(LD) $(LDFLAGS) --map=HORLOGE.map -o HORLOGE horloge.o

horloge.o: horloge.asm ../lib/horloge.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<

CLOUTEST: cloutest.asm cloutest.o
	$(LD) $(LDFLAGS) --map=CLOUTEST.map -o CLOUTEST cloutest.o

JOYCAL: joycal.asm joycal.o
	$(LD) $(LDFLAGS) --map=JOYCAL.map -o JOYCAL joycal.o

joycal.o: joycal.asm ../lib/joy.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=joycal.lst -o $@ $<

NEIGE: neige.asm neige.o
	$(LD) $(LDFLAGS) --map=NEIGE.map -o NEIGE neige.o

AYTEST: aytest.asm aytest.o
	$(LD) $(LDFLAGS) --map=AYTEST.map -o AYTEST aytest.o

TELE: tele.asm tele.o
	$(LD) $(LDFLAGS) --map=TELE.map -o TELE tele.o

SDTEST: sdtest.asm sdtest.o
	$(LD) $(LDFLAGS) --map=SDTEST.map -o SDTEST sdtest.o

cd.o mkdir.o pwd.o ls.o moniteur.o sdtest.o tele.o aytest.o cloutest.o neige.o graphe.o: %.o: %.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<

SIZE: size.asm size.o
	$(LD) $(LDFLAGS) --map=SIZE.map -o SIZE size.o
	$(OBJCOPY) -I binary -O ihex SIZE size.hex

type.o: type.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=type.lst -o $@ $<

cp.o: cp.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=cp.lst -o $@ $<

mv.o: mv.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=mv.lst -o $@ $<

rm.o: rm.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=rm.lst -o $@ $<

size.o: size.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=size.lst -o $@ $<

CPU: cpu.asm cpu.o
	$(LD) $(LDFLAGS) --map=CPU.map -o CPU cpu.o
	$(OBJCOPY) -I binary -O ihex CPU cpu.hex

cpu.o: cpu.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) --format=obj --6309 -I../bios --list=cpu.lst -o $@ $<

clean:
	rm -f *.o *.lst *.map *.hex *.EXE TYPE CP MV RM SIZE CPU CD MKDIR PWD LS MONITEUR SDTEST TELE AYTEST AYJOUE CLOUTEST JOYCAL HORLOGE NEIGE GRAPHE
	rm -f $(MORCEAUX_TXT:.txt=.MUS)

.PHONY: all clean MORCEAUX
