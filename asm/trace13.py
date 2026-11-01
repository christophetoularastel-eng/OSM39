import sys, importlib.util

spec = importlib.util.spec_from_file_location("emu", "emu6809.py")
emu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(emu)

asm_path, src_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

m = emu.OSM09()
data = open(asm_path, 'rb').read()
m.mem[0:len(data)] = data
m.install_table()
m.init_heap()
src_name = src_path.split('/')[-1]
out_name = out_path.split('/')[-1]
m.setup_args("ASM", src_name, out_name)
m.load_source_into_disk(src_path)
m.output_host_path = out_path
m.s = 0xDFEF
m.push16(emu.EXIT_MARKER)
m.pc = 0x0000

def rd16(a):
    return (m.mem[a] << 8) | m.mem[a + 1]

LC = 0x17B3
regbuf = 0x17FB
ld_oper = 0x17C7
inst_ptr = 0x17FF

opnames = {
    0x12: "NOP", 0x1A: "ORCC", 0x1C: "ANDCC", 0x1D: "SEX", 0x1E: "EXG",
    0x1F: "TFR", 0x39: "RTS", 0x3A: "ABX", 0x3B: "RTI", 0x3D: "MUL",
    0x34: "PSHS", 0x35: "PULS", 0x36: "PSHU", 0x37: "PULU", 0x16: "LBRA",
    0x17: "LBSR", 0x8D: "BSR", 0x86: "LDA#", 0x81: "CMPA#", 0x8E: "LDX#",
    0xBD: "JSR", 0x7E: "JMP", 0x10: "P10", 0x1F: "TFR",
}

import dis
def disasm_one():
    pc = m.pc
    op = m.mem[pc]
    nm = opnames.get(op, "?%02X" % op)
    return "%04X: %s" % (pc, nm)

# arm: watch instructions from first ParseReg for LC==0x010F until pr_ok or pi_ix_bad
arm_pc = 0x0EBE
stop_at = (0x0F50, 0x0D62, 0x0D59)
started = False
saw_parse = False
count = 0
orig_step = m.step

def step():
    global started, saw_parse, count
    m.pc = m.pc
    if started:
        print("  %s  CC=%02X A=%02X B=%02X X=%04X Y=%04X U=%04X S=%04X reg='%s%s%s%s' oper=%04X" % (
            disasm_one(), m.cc, m.a, m.b, m.x, m.y, m.u, m.s,
            *(chr(m.mem[regbuf+i]) if 32 <= m.mem[regbuf+i] < 127 else '.' for i in range(4)),
            rd16(ld_oper)))
        count += 1
        if m.pc in stop_at or count > 60:
            started = False
    orig_step()
    if not started and m.pc == arm_pc and rd16(LC) == 0x010F:
        # the FIRST ParseReg call for exg d,x (need to skip the 'x' one)
        started = True
        saw_parse = True
        count = 0
        print(">>> trace from ParseReg entry for LC=$010F")

m.step = step
try:
    m.run_program()
except Exception as e:
    print("exception:", e)
