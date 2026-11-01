lwasm -r -lmycpu6809.lst -omycpu6809.bin mycpu6809.asm
mmake SUBTARGET=py09 SOURCES=homebrew/py09.cpp REGENIE=1
minipro -u(-P) -p M28C64 -w osm09.bin
sudo mkfs.vfat -F 16 -n "SD6809" /dev/mmcblk0p1
