BIOS d'OSM39 (HD6309) : l'EPROM de 8 Ko et sa seconde partie BIOS2.

  make -C bios          -> osm39.bin (EPROM) et BIOS2 (/BIN/BIOS2 de la carte)
  make -C bios osm39.hex

Les deux vont ensemble : BIOS2 n'est chargé que si sa longueur et sa somme
sont celles inscrites dans l'EPROM. ./deploy_sd.sh les copie dans
dist/EPROM et dist/SD/BIN.

Carte mémoire : docs/memory-map.md. Règles et pièges : AGENTS.md.
hardware.inc et sysfunc.inc sont générés (update_includes.py) : ne pas
les éditer.
