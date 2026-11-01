#!/usr/bin/env python3
import sys

memory = {}
max_addr = 0

def parse_srec(line):
    global max_addr
    line = line.strip()
    if not line or len(line) < 4 or not line.startswith('S'):
        return
    rec_type = line[1]
    if rec_type not in '0123456789':
        return
    try:
        count = int(line[2:4], 16)
    except:
        return
    addr_str = line[4:]
    if rec_type in '056':
        return
    if rec_type == '1':
        addr_len = 2
    elif rec_type == '2':
        addr_len = 3
    elif rec_type == '3':
        addr_len = 4
    elif rec_type in '789':
        return
    else:
        return
    try:
        addr = int(addr_str[:addr_len*2], 16)
        data_len = count - addr_len - 1
        if data_len <= 0:
            return
        data_hex = addr_str[addr_len*2:addr_len*2 + data_len*2]
        for i in range(data_len):
            memory[addr + i] = int(data_hex[i*2:i*2+2], 16)
        if addr + data_len - 1 > max_addr:
            max_addr = addr + data_len - 1
    except:
        return

with open(sys.argv[1], 'r') as f:
    for line in f:
        parse_srec(line)

output = bytearray()
for addr in range(0x2000):
    output.append(memory.get(addr + 0xe000, 0xFF))

with open(sys.argv[2], 'wb') as f:
    f.write(output)
