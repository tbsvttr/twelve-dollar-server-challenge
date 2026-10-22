#!/usr/bin/env python3
"""Read Darwin cumulative CPU/QoS counters. No signals, attachment, or changes."""
import ctypes
import datetime
import json
import re
import sys
from pathlib import Path

header = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sys/resource.h")
body = re.search(r"struct rusage_info_v6 \{(.*?)\n\};", header.read_text(), re.S).group(1)
fields = []
for line in body.splitlines():
    match = re.match(r"\s*(uint8_t|uint64_t)\s+(ri_\w+)(?:\[(\d+)\])?;", line)
    if match:
        kind, name, count = match.groups()
        value = ctypes.c_uint8 if kind == "uint8_t" else ctypes.c_uint64
        fields.append((name, value * int(count) if count else value))

class Usage(ctypes.Structure):
    _fields_ = fields

lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int
rows = []
for pid in map(int, sys.argv[1:]):
    usage = Usage()
    ctypes.set_errno(0)
    result = lib.proc_pid_rusage(pid, 6, ctypes.byref(usage))
    row = dict(pid=pid, result=result, errno=ctypes.get_errno())
    if result == 0:
        row.update({name: getattr(usage, name) for name, _ in fields
                    if "time" in name or "instructions" in name or "cycles" in name})
    rows.append(row)
print(json.dumps(dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     struct_size=ctypes.sizeof(Usage), rows=rows), indent=2))
