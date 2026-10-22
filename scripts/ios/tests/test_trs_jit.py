"""Tests für den JIT-Helfer (src-tauri/gen/apple/lldb/trs_jit.py) mit nachgebautem LLDB.

    python3 -I -B scripts/ios/tests/test_trs_jit.py
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.join(HERE, '../../../src-tauri/gen/apple/lldb')]

import trs_jit  # noqa: E402

def brk(imm): return struct.pack('<I', 0xD4200000 | (imm << 5))
class Reg:
    def __init__(s, f, n): s.f, s.n = f, n
    def IsValid(s): return True
    def GetValueAsUnsigned(s): return s.f.regs.get(s.n, 0)
    def SetValueFromCString(s, v, e): s.f.regs[s.n] = int(v, 16)
class Frame:
    def __init__(s, pc, regs): s.pc, s.regs = pc, regs
    def FindRegister(s, n): return Reg(s, n)
    def GetPC(s): return s.pc
    def SetPC(s, pc): s.pc = pc
class Proc:
    def __init__(s): s.mem = {}; s.writes = []; s.allocs = []
    def IsValid(s): return True
    def ReadMemory(s, a, n, e): return bytes(s.mem.get(a + i, 0) for i in range(n))
    def WriteMemory(s, a, d, e): s.writes.append((a, len(d))); [s.mem.__setitem__(a + i, b) for i, b in enumerate(d)]; return len(d)
    def AllocateMemory(s, n, p, e): s.allocs.append((n, p)); return 0x300000000
class Thread:
    def __init__(s, f): s.f = f
    def IsValid(s): return True
    def GetFrameAtIndex(s, i): return s.f
class Ctx:
    def __init__(s, p, f): s.p, s.t = p, Thread(f)
    def GetThread(s): return s.t
    def GetProcess(s): return s.p
hook = trs_jit.JitStopHook(None, None, None)
p = Proc()
def stop(pc, imm, regs):
    for i, b in enumerate(brk(imm)): p.mem[pc + i] = b
    f = Frame(pc, regs); r = hook.handle_stop(Ctx(p, f), None); return r, f
# 1) legacy 0x69 before extension -> 0x690000E0, continue, pc+4
r, f = stop(0x1000, 0x69, {'x0': 0x4000}); assert r is False and f.regs['x0'] == 0x690000E0 and f.pc == 0x1004, (r, f.regs)
# 2) send script (cmd 2) -> extension flag
r, f = stop(0x2000, 0xF00D, {'x16': 2, 'x0': 0x5000, 'x1': 10}); assert r is False and trs_jit._state['extension']
# 3) 0x69 after extension -> allocates RX, touches pages, x0 = address
p.writes.clear(); r, f = stop(0x3000, 0x69, {'x0': 0x8000}); assert f.regs['x0'] == 0x300000000 and p.allocs[-1] == (0x8000, 6) and len(p.writes) == 2, (f.regs, p.allocs, p.writes)
# 4) cmd 1 prepare existing region 3 pages
p.writes.clear(); r, f = stop(0x4000, 0xF00D, {'x16': 1, 'x0': 0x10000, 'x1': 0x9000}); assert len(p.writes) == 3 and f.regs['x0'] == 0x10000
# 5) cmd 4 patch region -> one write of full length
p.writes.clear(); r, f = stop(0x5000, 0xF00D, {'x16': 4, 'x0': 0x20000, 'x1': 16}); assert p.writes == [(0x20000, 16)]
# 6) detach cmd 0 / cmd 3 ignored but continue
r, f = stop(0x6000, 0xF00D, {'x16': 0}); assert r is False and f.pc == 0x6004
# 7) normal non-brk stop -> stays stopped, pc unchanged
p.mem.update({0x7000+i: b for i, b in enumerate(struct.pack('<I', 0xD503201F))}); f = Frame(0x7000, {}); assert hook.handle_stop(Ctx(p, f), None) is True and f.pc == 0x7000
# 8) user brk #0 -> stop
r, f = stop(0x8000, 0, {}); assert r is True and f.pc == 0x8000
print('alle JIT-Tests ok')
