"""Minimal minidump reader (stdlib only): exception, faulting module, heuristic stack scan."""
import struct, sys, os, collections

def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u64(b, o): return struct.unpack_from('<Q', b, o)[0]

EXC_NAMES = {0xC0000005: 'ACCESS_VIOLATION', 0xC00000FD: 'STACK_OVERFLOW', 0x80000003: 'BREAKPOINT',
             0xC0000409: 'STACK_BUFFER_OVERRUN / fail fast', 0xC000001D: 'ILLEGAL_INSTRUCTION',
             0xE06D7363: 'C++ EXCEPTION', 0xC0000374: 'HEAP_CORRUPTION', 0xC0000094: 'INT_DIVIDE_BY_ZERO'}

def analyze(path, scan_limit):
    b = open(path, 'rb').read()
    if b[:4] != b'MDMP':
        print('  not a minidump'); return None
    nstreams, dirrva = u32(b, 8), u32(b, 12)
    streams = {}
    for i in range(nstreams):
        t, size, rva = struct.unpack_from('<III', b, dirrva + i * 12)
        streams.setdefault(t, (size, rva))

    mods = []
    if 4 in streams:
        _, rva = streams[4]
        n = u32(b, rva)
        for i in range(n):
            o = rva + 4 + i * 108
            base, size = u64(b, o), u32(b, o + 8)
            ts, namerva = u32(b, o + 16), u32(b, o + 20)
            nlen = u32(b, namerva)
            name = b[namerva + 4:namerva + 4 + nlen].decode('utf-16le', 'replace')
            mods.append((base, size, name, ts))
    mods.sort()

    def modof(addr):
        for base, size, name, _ in mods:
            if base <= addr < base + size:
                return '%s+0x%X' % (os.path.basename(name), addr - base)
        return None

    # memory ranges
    ranges = []
    if 5 in streams:
        _, rva = streams[5]
        n = u32(b, rva)
        for i in range(n):
            start, dsize, drva = struct.unpack_from('<QII', b, rva + 4 + i * 16)
            ranges.append((start, dsize, drva))
    if 9 in streams:
        _, rva = streams[9]
        n, base_rva = u64(b, rva), u64(b, rva + 8)
        cur = base_rva
        for i in range(n):
            start, dsize = struct.unpack_from('<QQ', b, rva + 16 + i * 16)
            ranges.append((start, dsize, cur))
            cur += dsize

    def readmem(addr, length):
        for start, dsize, drva in ranges:
            if start <= addr and addr + length <= start + dsize:
                off = drva + (addr - start)
                return b[off:off + length]
        return None

    threads = {}
    thread_order = []
    if 3 in streams:
        _, rva = streams[3]
        n = u32(b, rva)
        for i in range(n):
            o = rva + 4 + i * 48
            tid = u32(b, o)
            stk_start, stk_size, stk_rva = u64(b, o + 24), u32(b, o + 32), u32(b, o + 36)
            ctx_size, ctx_rva = u32(b, o + 40), u32(b, o + 44)
            threads[tid] = (stk_start, stk_size, stk_rva, ctx_rva)
            thread_order.append(tid)

    if 6 not in streams:
        print('  no exception stream'); return None
    _, rva = streams[6]
    tid = u32(b, rva)
    code, flags = u32(b, rva + 8), u32(b, rva + 12)
    addr = u64(b, rva + 24)
    nparams = u32(b, rva + 32)
    params = [u64(b, rva + 40 + 8 * k) for k in range(min(nparams, 15))]
    ctx_rva = u32(b, rva + 8 + 152 + 4)

    print('  Exception: 0x%08X %s' % (code, EXC_NAMES.get(code, '')))
    print('  Address:   0x%X  (%s)' % (addr, modof(addr) or 'no module'))
    if code == 0xC0000005 and len(params) >= 2:
        print('  AV kind:   %s address 0x%X' % ({0: 'read', 1: 'write', 8: 'execute'}.get(params[0], params[0]), params[1]))
    idx = thread_order.index(tid) if tid in thread_order else -1
    print('  Thread:    id %d (index %d of %d threads; index 0 is usually the process main thread)' % (tid, idx, len(thread_order)))
    rsp = u64(b, ctx_rva + 0x98)
    rip = u64(b, ctx_rva + 0xF8)
    regs = {n_: u64(b, ctx_rva + off) for n_, off in [('rax', 0x78), ('rcx', 0x80), ('rdx', 0x88), ('rbx', 0x90), ('rsi', 0xA8), ('rdi', 0xB0), ('r8', 0xB8)]}
    print('  RIP 0x%X  RSP 0x%X  ' % (rip, rsp) + ' '.join('%s=0x%X' % kv for kv in regs.items()))

    # heuristic stack scan: return-address-like values that fall inside module images
    stk = threads.get(tid)
    frames = []
    if stk:
        stk_start, stk_size, stk_rva, _ = stk
        data = b[stk_rva:stk_rva + stk_size] if stk_rva else readmem(stk_start, stk_size)
        if data:
            first = max(0, (rsp - stk_start) & ~7)
            for off in range(first, len(data) - 7, 8):
                v = u64(data, off)
                m = modof(v)
                if m and not m.lower().startswith(('ntdll.dll+0x0', )):
                    # prefer values preceded by a call opcode when code memory is available
                    code_before = readmem(v - 7, 7)
                    is_call = None
                    if code_before:
                        is_call = code_before[2] == 0xE8 or code_before[5] == 0xFF or code_before[4] == 0xFF or code_before[1] == 0xFF or code_before[0] == 0xFF
                    frames.append((m, is_call))
    print('  Stack scan (return-address candidates, top first):')
    shown = 0
    for m, is_call in frames:
        if is_call is False:
            continue
        print('    ' + m + ('' if is_call else '  (?)'))
        shown += 1
        if shown >= scan_limit:
            break
    counts = collections.Counter(m.split('+')[0] for m, c in frames if c is not False)
    print('  Modules on stack: ' + ', '.join('%s x%d' % kv for kv in counts.most_common(12)))
    interesting = [m for m in mods if any(k in m[2].lower() for k in ('ue4ss', 'lua', 'speech', 'mods\\', 'dsound', '.asi', 'nvda', 'zdsr', 'universalspeech'))]
    return (modof(addr), code, [os.path.basename(m[2]) for m in interesting])

if __name__ == '__main__':
    limit = int(os.environ.get('SCAN_LIMIT', '40'))
    for p in sys.argv[1:]:
        print('=== ' + os.path.basename(p))
        if os.path.getsize(p) == 0:
            print('  empty (dump writer failed)'); continue
        r = analyze(p, limit)
        if r and os.environ.get('SHOW_MODS'):
            print('  Injected/mod modules loaded: ' + ', '.join(r[2]))
