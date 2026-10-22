"""JIT für Minecraft Java beim Start aus Xcode (▶ Run).

Xcodes Debugger hängt sich an die App – damit gilt sie als „debugged“ (CS_DEBUGGED) und darf
ausführbaren Speicher anlegen: JIT ist an. Auf Geräten mit iOS 26 und TXM reicht das nicht: Dort
fragt die Engine den Debugger per `brk #0xf00d` / `brk #0x69` nach vorbereiteten JIT-Regionen
(Amethyst-iOS, „universal JIT calls“). Dieses Skript beantwortet sie wie StikDebug mit
UniversalJIT26.js + UniversalJIT26Extension.js – nur eben in Xcodes LLDB.

Geladen von trs-jit.lldbinit (Schema trs-launcher_iOS → Run → LLDB Init File).

Befehle (x16 bei brk #0xf00d, Argumente in x0/x1, Ergebnis in x0):
  0 Detach                     – ignoriert, Xcode bleibt angehängt
  1 PrepareRegion(addr, len)   – addr 0: RX-Speicher anlegen; danach Seiten über den Debugger beschreiben
  2 SendJITScript(text, len)   – JavaScript für StikDebug; hier nur Merker „Erweiterung geladen“
  3 SetDetachAfterFirstBr(b)   – ignoriert (bleibt angehängt)
  4 PrepareRegionForPatching   – Bereich lesen und über den Debugger zurückschreiben
brk #0x69 (alt): vor der Erweiterung 0x690000E0 („neues Skript“), danach PrepareRegion(0, x0).
"""

import lldb

BRK_MASK = 0xFFE0001F
BRK_BASE = 0xD4200000
PAGE = 0x4000
LEGACY_RESULT = 0x690000E0

_state = {'extension': False}


def _log(msg):
    print(f'[TRS-JIT] {msg}')


def _brk_immediate(process, pc):
    error = lldb.SBError()
    data = process.ReadMemory(pc, 4, error)
    if not error.Success() or data is None or len(data) != 4:
        return None
    instr = int.from_bytes(data, 'little')
    if (instr & BRK_MASK) != BRK_BASE:
        return None
    return (instr >> 5) & 0xFFFF


def _reg(frame, name):
    value = frame.FindRegister(name)
    return value.GetValueAsUnsigned() if value.IsValid() else 0


def _set_reg(frame, name, number):
    value = frame.FindRegister(name)
    error = lldb.SBError()
    value.SetValueFromCString(hex(number), error)
    return error.Success()


def _touch_pages(process, addr, length):
    """Jede Seite über den Debugger einmal schreiben (gleicher Inhalt) – wie prepare_memory_region in StikDebug."""
    start = addr & ~(PAGE - 1)
    end = addr + length
    page = start
    while page < end:
        error = lldb.SBError()
        byte = process.ReadMemory(page, 1, error)
        if error.Success() and byte:
            process.WriteMemory(page, byte, error)
        if not error.Success():
            _log(f'Seite 0x{page:x} nicht vorbereitet: {error.GetCString()}')
        page += PAGE


def _prepare_region(process, frame, addr, length):
    if addr == 0 and length == 0:
        return
    if addr == 0:
        error = lldb.SBError()
        addr = process.AllocateMemory(length, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, error)
        if not error.Success() or addr in (0, lldb.LLDB_INVALID_ADDRESS):
            _log(f'RX-Speicher ({length} Bytes) nicht angelegt: {error.GetCString()}')
            return
        _log(f'JIT-Region 0x{addr:x} ({length} Bytes)')
    _touch_pages(process, addr, length)
    _set_reg(frame, 'x0', addr)


def _patch_region(process, addr, length):
    if length == 0:
        return
    error = lldb.SBError()
    data = process.ReadMemory(addr, length, error)
    if error.Success() and data:
        process.WriteMemory(addr, data, error)
    if not error.Success():
        _log(f'Patch-Bereich 0x{addr:x} nicht vorbereitet: {error.GetCString()}')


def _handle(process, frame, immediate):
    x0 = _reg(frame, 'x0')
    x1 = _reg(frame, 'x1')
    if immediate == 0x69:
        if not _state['extension']:
            _set_reg(frame, 'x0', LEGACY_RESULT)
        else:
            _prepare_region(process, frame, 0, x0)
        return
    if immediate == 0x68:
        _state['extension'] = True
        return
    command = _reg(frame, 'x16')
    if command == 1:
        _prepare_region(process, frame, x0, x1)
    elif command == 2:
        _state['extension'] = True
    elif command == 4:
        _patch_region(process, x0, x1)
    elif command in (0, 3):
        pass  # Detach-Wünsche: Xcode bleibt angehängt, JIT bleibt damit verfügbar.
    else:
        _log(f'Unbekannter JIT-Befehl {command}')


class JitStopHook:
    """Stop-Hook: JIT-Anfragen der Engine beantworten und sofort weiterlaufen lassen."""

    def __init__(self, target, extra_args, internal_dict):
        self.target = target

    def handle_stop(self, exe_ctx, stream):
        thread = exe_ctx.GetThread()
        process = exe_ctx.GetProcess()
        if not thread.IsValid() or not process.IsValid():
            return True
        frame = thread.GetFrameAtIndex(0)
        pc = frame.GetPC()
        immediate = _brk_immediate(process, pc)
        if immediate not in (0xF00D, 0x69, 0x68):
            return True  # normaler Halt (eigener Breakpoint, Absturz …): Xcode zeigt ihn an
        _handle(process, frame, immediate)
        frame.SetPC(pc + 4)  # über den brk springen
        return False  # weiterlaufen


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f'target stop-hook add -P {__name__}.JitStopHook')
    _log('JIT-Helfer geladen – Minecraft Java kann aus Xcode mit JIT starten.')
