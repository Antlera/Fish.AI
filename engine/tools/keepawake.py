"""Keep the display on and the machine awake while Fish.AI's "stay online" switch is on.

This is the same mechanism a video player or a slide show uses: the Windows API
SetThreadExecutionState with ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED tells the power
manager that an application needs the screen, so the idle timers that turn the display
off (and lock it afterwards) or put the machine to sleep do not fire. No input is
simulated, no admin rights are needed, and `powercfg /requests` shows it plainly.

It does NOT defeat a lock that a group policy enforces from the last-input time; that is a
different mechanism and out of scope here on purpose.

Usage: python keepawake.py <parent-pid>
The request is held as long as this process lives. It exits by itself when the parent
(server.mjs) is gone, so a crashed launcher never leaves the screen pinned on.
"""
import ctypes
import sys
import time

ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001
ES_DISPLAY_REQUIRED = 0x00000002
SYNCHRONIZE = 0x00100000
WAIT_TIMEOUT = 0x102

kernel32 = ctypes.windll.kernel32


def main() -> int:
    parent = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    handle = kernel32.OpenProcess(SYNCHRONIZE, False, parent) if parent else None
    flags = ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
    if kernel32.SetThreadExecutionState(flags) == 0:
        print("SetThreadExecutionState failed", flush=True)
        return 1
    print("keep-awake on", flush=True)
    try:
        while True:
            if handle:
                # Block up to 30 s on the parent's handle; it signals when the parent exits.
                if kernel32.WaitForSingleObject(handle, 30_000) != WAIT_TIMEOUT:
                    break
            else:
                time.sleep(30)
            # Re-assert: harmless, and guards against anything that reset the thread state.
            kernel32.SetThreadExecutionState(flags)
    finally:
        kernel32.SetThreadExecutionState(ES_CONTINUOUS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
