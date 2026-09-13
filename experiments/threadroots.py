"""For each dump: identify the faulting thread's root (bottom of stack) and list threads whose root is UE4SS.dll."""
import struct, sys, os

def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u64(b, o): return struct.unpack_from('<Q', b, o)[0]

def load(path):
    b = open(path, 'rb').read()
    nstreams, dirrva = u32(b, 8), u32(b, 12)
    streams = {}
    for i in range(nstreams):
        t, size, rva = struct.unpack_from('<III', b, dirrva + i * 12)
        streams.setdefault(t, (size, rva))
    mods = []
    _, rva = streams[4]
    for i in range(u32(b, rva)):
        o = rva + 4 + i * 108
        base, size, namerva = u64(b, o), u32(b, o + 8), u32(b, o + 20)
        nlen = u32(b, namerva)
        mods.append((base, size, os.path.basename(b[namerva + 4:namerva + 4 + nlen].decode('utf-16le', 'replace'))))
    ranges = []
    if 5 in streams:
        _, rva = streams[5]
        for i in range(u32(b, rva)):
            start, dsize, drva = struct.unpack_from('<QII', b, rva + 4 + i * 16)
            ranges.append((start, dsize, drva))
    if 9 in streams:
        _, rva = streams[9]
        n, cur = u64(b, rva), u64(b, rva + 8)
        for i in range(n):
            start, dsize = struct.unpack_from('<QQ', b, rva + 16 + i * 16)
            ranges.append((start, dsize, cur)); cur += dsize
    return b, streams, mods, ranges

def main(path):
    b, streams, mods, ranges = load(path)
    def modof(a):
        for base, size, name in mods:
            if base <= a < base + size:
                return name, a - base
        return None
    def stackdata(st, sz, srva):
        if srva:
            return b[srva:srva + sz]
        for start, dsize, drva in ranges:
            if start <= st and st + sz <= start + dsize:
                return b[drva + st - start: drva + st - start + sz]
        return None
    _, rva = streams[6]
    ftid = u32(b, rva)
    _, trva = streams[3]
    n = u32(b, trva)
    print('=== ' + os.path.basename(path))
    ue4ss_rooted = []
    for i in range(n):
        o = trva + 4 + i * 48
        tid = u32(b, o)
        st, sz, srva = u64(b, o + 24), u32(b, o + 32), u32(b, o + 36)
        data = stackdata(st, sz, srva)
        if not data:
            continue
        hits = []
        for off in range(0, len(data) - 7, 8):
            m = modof(u64(data, off))
            if m and m[0] not in ('ntdll.dll', 'KERNEL32.DLL', 'kernel32.dll', 'KERNELBASE.dll', 'ucrtbase.dll'):
                hits.append('%s+0x%X' % m)
        root = hits[-3:] if hits else []
        if tid == ftid or i == 0:
            print('  thread index %d id %d %s: bottom frames (deepest last): %s' % (i, tid, '[FAULTING]' if tid == ftid else '[main]', ', '.join(root) or 'none'))
        if hits and hits[-1].startswith('UE4SS.dll'):
            ue4ss_rooted.append((i, tid, hits[-1]))
    print('  threads whose deepest non-system frame is UE4SS.dll: ' + '; '.join('idx %d id %d %s' % t for t in ue4ss_rooted))

for p in sys.argv[1:]:
    if os.path.getsize(p):
        main(p)
