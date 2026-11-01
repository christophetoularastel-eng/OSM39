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

# adresses (listing actuel)
LC        = 0x17B3
EmitCount = 0x17B5
pass_no   = 0x17BB
pi_tmp    = 0x17EF
pi_tmp2   = 0x17F1
idx_ind   = 0x17F3
idx_mode  = 0x17F4
idx_acc   = 0x17F5
idx_reg   = 0x17F6
idx_sym   = 0x17F7
regbuf    = 0x17FB
inst_ptr  = 0x17FF
inst_ptr  = 0x17FF
inst_pfx  = 0x1803
inst_op   = 0x1804
inst_extra= 0x1805
inst_xlen = 0x1808
inst_size = 0x1809
expr_flag = 0x180A
no_undef  = 0x180B
sym_count = 0x180C

WATCH = {
    0x05D7: "ParseInst",
    0x0697: "pi_inh_oper",
    0x0C8D: "pi_tfr",
    0x0D59: "pi_badop",
    0x0D62: "pi_ix_bad",
    0x0D6B: "pi_rngerr",
    0x0CDF: "pi_pushpull",
    0x1005: "EmitInst",
    0x11FE: "EvalSymbol",
    0x1422: "SymFind",
    0x0EBE: "ParseReg",
    0x0E24: "ReadRegName",
    0x0F50: "pr_ok",
    0x0F54: "pr_no",
    0x0DBB: "SkipSpaces",
}

def rd16(a):
    return (m.mem[a] << 8) | m.mem[a + 1]

ld_oper = 0x17C7

def dump(tag, pc):
    regs = "".join(chr(m.mem[regbuf+i]) if m.mem[regbuf+i] else '.' for i in range(4))
    oper = rd16(ld_oper)
    oper_bytes = "".join(chr(m.mem[(oper+i) & 0xFFFF]) if 32 <= m.mem[(oper+i) & 0xFFFF] < 127 else '.' for i in range(12))
    if oper:
        oper_hex = " ".join("%02x" % m.mem[(oper+i) & 0xFFFF] for i in range(12))
    else:
        oper_hex = ""
    ip = rd16(inst_ptr)
    entry = " ".join("%02x" % m.mem[(ip+i) & 0xFFFF] for i in range(19))
    print("[dbg] pc=$%04X %-13s pass=%d LC=$%04X EmitCount=$%04X "
          "X=$%04X A=$%02X B=$%02X CC=$%02X "
          "pi_tmp=$%04X pi_tmp2=$%04X idx=%d%d%d%d sym=%d "
             "reg='%s' oper='%s' operhex=[%s] inst_ptr=$%04X tbl=[%s] inst=pfx$%02X op$%02X extra=%02x%02x%02x xlen$%02X size$%02X "
             "expr=$%02X no_undef=$%02X sym_count=$%02X"
             % (pc, tag, m.mem[pass_no],
                rd16(LC), rd16(EmitCount),
                m.x, m.a, m.b, m.cc,
                rd16(pi_tmp), rd16(pi_tmp2),
                m.mem[idx_ind], m.mem[idx_mode], m.mem[idx_acc], m.mem[idx_reg], m.mem[idx_sym],
                regs, oper_bytes, oper_hex, ip, entry,
                m.mem[inst_pfx], m.mem[inst_op],
                m.mem[inst_extra], m.mem[inst_extra+1], m.mem[inst_extra+2],
                m.mem[inst_xlen], m.mem[inst_size],
                m.mem[expr_flag], m.mem[no_undef], m.mem[sym_count]))

orig_step = m.step
def step():
    pc0 = m.pc
    if pc0 in WATCH:
        dump(WATCH[pc0], pc0)
    orig_step()
m.step = step

try:
    m.run_program()
except Exception as e:
    print("exception:", e)
