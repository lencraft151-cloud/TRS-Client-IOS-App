"""Minimaler Ersatz für das lldb-Modul, damit test_trs_jit.py ohne Xcode läuft."""
ePermissionsReadable = 2
ePermissionsExecutable = 4
LLDB_INVALID_ADDRESS = 2**64 - 1


class SBError:
    def __init__(self):
        self.ok = True

    def Success(self):
        return self.ok

    def GetCString(self):
        return 'error'
