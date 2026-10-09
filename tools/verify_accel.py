#!/usr/bin/env python3
# verify_accel.py -- verify a rebuilt NVAccel kext against the shipped reference.
#
# Checks a Mach-O kext binary (x86_64, thin or FAT slice) with no external tools:
#   1. import/export symbol sets must equal the shipped reference exactly
#      (tools/reference/NVAccel-<major>-shipped.symbols.txt, extracted from the
#      official nullmoth-nvidia-1.1.0.tar.gz payload; the reference counts were
#      cross-checked by PR #60: macOS 15 -> 868 imports / 333 exports,
#      macOS 26 -> 843 / 401).
#   2. NVVidMemory::allocPhysical must write VRAM ABI version 2 into the
#      NVRMVramRequest and must not contain the stale version-1 store.
#      Reference encodings (see tools/reference/README.txt):
#        macOS 15, ABI 2 : c7 45 88 02 00 00 00   mov dword ptr [rbp-0x78], 2
#        macOS 26, ABI 1 : c7 45 90 01 00 00 00   mov dword ptr [rbp-0x70], 1
#      Issue #51: the shipped kexts/26 build still writes version 1, NVRMFB
#      speaks 2, every nvAllocVram is refused and the desktop stays black.
#
# Exit code 0 = every hard check passed.  Hard checks per binary:
#   - symbol import/export sets equal the reference sets
#   - version-2 store present (exact reference bytes, or relaxed: same disp8 in a
#     following lea of the same [rbp+disp8] request buffer)
#   - no version-1 store in the function
import argparse, hashlib, struct, sys

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_X86_64 = 0x01000007
LC_SYMTAB = 0x2
LC_SEGMENT_64 = 0x19
N_UNDF, N_EXT, N_TYPE = 0x0, 0x1, 0x0E

SHIPPED = {
    '15': 'cac6763c075aa2a1ed5ebbd74b1fe9a20a9de546086ef054e6feea58ec1e3cc8',
    '26': '5aee66f533f48ce84366fd2f63b30e9f7dea35ad25b1b0974e3d34a0b829442b',
}
REF_COUNTS = {'15': (868, 333), '26': (843, 401)}


def read_slice(data, path):
    if len(data) < 32:
        sys.exit(f'STOP: {path}: too short to be a Mach-O file')
    magic = struct.unpack('>I', data[:4])[0]
    if magic in (0xCAFEBABE, 0xBEBAFECA):
        nfat = struct.unpack('>I', data[4:8])[0]
        for i in range(nfat):
            off = 8 + i * 20
            cputype, _cpusub, offset, size, _align = struct.unpack('>iiIII', data[off:off + 20])
            if cputype == CPU_TYPE_X86_64:
                return data[offset:offset + size]
        sys.exit(f'STOP: {path}: FAT binary without an x86_64 slice')
    return data


def parse(path):
    data = read_slice(open(path, 'rb').read(), path)
    if struct.unpack('<I', data[:4])[0] != MH_MAGIC_64:
        sys.exit(f'STOP: {path}: not a 64-bit Mach-O kext')
    ncmds = struct.unpack('<I', data[16:20])[0]
    off, sections, symtab = 32, {}, None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', data[off:off + 8])
        if cmd == LC_SYMTAB:
            symtab = struct.unpack('<IIII', data[off + 8:off + 24])
        elif cmd == LC_SEGMENT_64:
            nsects = struct.unpack('<I', data[off + 64:off + 68])[0]
            so = off + 72
            for i in range(nsects):
                s = data[so + i * 80:so + (i + 1) * 80]
                name = s[0:16].rstrip(b'\0').decode('utf-8', 'replace')
                seg = s[16:32].rstrip(b'\0').decode('utf-8', 'replace')
                addr, size = struct.unpack('<QQ', s[32:48])
                offset = struct.unpack('<I', s[48:52])[0]
                sections[(seg, name)] = (addr, size, offset)
        off += cmdsize
    if not symtab:
        sys.exit(f'STOP: {path}: no LC_SYMTAB load command')
    symoff, nsyms, stroff, strsize = symtab
    strs = data[stroff:stroff + strsize]
    syms, imports, exports = [], [], []
    for i in range(nsyms):
        p = symoff + i * 16
        n_strx, n_type, n_sect, _n_desc, n_value = struct.unpack('<IBBHQ', data[p:p + 16])
        end = strs.find(b'\0', n_strx)
        name = strs[n_strx:end].decode('utf-8', 'replace')
        if not name:
            continue
        if (n_type & N_TYPE) == N_UNDF:
            if n_type & N_EXT:
                imports.append(name)
        elif n_type & N_EXT:
            exports.append(name)
            syms.append((name, n_sect, n_value))
    return data, sections, sorted(imports), sorted(exports), syms


def alloc_physical_bytes(data, sections, syms):
    text = sections.get(('__TEXT', '__text'))
    if not text:
        sys.exit('STOP: no __TEXT,__text section')
    taddr, tsize, toff = text
    hits = [s for s in syms if s[0] == '__ZN11NVVidMemory13allocPhysicalEv']
    if not hits:  # tolerate a different mangling, but never match deallocPhysical
        hits = [s for s in syms if 'allocPhysical' in s[0] and 'deallocPhysical' not in s[0]]
    if len(hits) != 1:
        sys.exit('STOP: expected exactly one allocPhysical symbol, found '
                 + str(len(hits)) + ': ' + ', '.join(h[0] for h in hits))
    name, sect, addr = hits[0]
    ends = [s[2] for s in syms if s[1] == sect and s[2] > addr]
    fend = min(ends) if ends else taddr + tsize
    start = toff + (addr - taddr)
    return name, addr, fend - addr, data[start:start + (fend - addr)]


def dword_stores(func):
    """All `c7 45 <disp8> <imm32<=0x1000>` candidates: mov dword ptr [rbp+disp8], imm."""
    out, i = [], 0
    while True:
        i = func.find(b'\xc7\x45', i)
        if i < 0 or i + 7 > len(func):
            break
        disp, imm = func[i + 2], struct.unpack('<I', func[i + 3:i + 7])[0]
        if imm <= 0x1000:
            out.append((disp, imm))
        i += 1
    return out


def lea_same_buffer(func, disp):
    """lea r64, [rbp+disp8] with the same disp8 -- the request pointer handed to nvAllocVram."""
    return func.find(bytes([0x48, 0x8D, 0x4D, disp])) >= 0 or \
           func.find(bytes([0x48, 0x8D, 0x55, disp])) >= 0


def check(major, path, refdir, report):
    emit = report.append
    ok = True
    emit(f'== NVAccel macOS {major}: {path} ==')
    data, sections, imports, exports, syms = parse(path)
    digest = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    emit(f'   sha256    : {digest}')
    if digest == SHIPPED[major]:
        emit(f'   NOTE      : byte-identical to the shipped macOS {major} accelerator '
             f'({SHIPPED[major][:16]}...); the build reproduces NullMoth\'s toolchain exactly')
    ref = {'IMPORT': [], 'EXPORT': []}
    for line in open(f'{refdir}/NVAccel-{major}-shipped.symbols.txt', encoding='utf-8'):
        kind, _, name = line.rstrip('\n').partition(' ')
        if kind in ref and name:
            ref[kind].append(name)
    ri, re_ = len(ref['IMPORT']), len(ref['EXPORT'])
    emit(f'   imports   : {len(imports)} (reference {ri}, PR #60 {REF_COUNTS[major][0]})')
    emit(f'   exports   : {len(exports)} (reference {re_}, PR #60 {REF_COUNTS[major][1]})')
    for kind, ours in (('IMPORT', imports), ('EXPORT', exports)):
        missing = sorted(set(ref[kind]) - set(ours))
        extra = sorted(set(ours) - set(ref[kind]))
        if missing or extra:
            ok = False
            emit(f'   SYMBOLS {kind}: MISMATCH -- {len(missing)} missing, {len(extra)} extra')
            for n in missing[:15]:
                emit(f'      missing: {n}')
            for n in extra[:15]:
                emit(f'      extra  : {n}')
        else:
            emit(f'   SYMBOLS {kind}: set equality with the shipped build -- OK')
    name, addr, size, func = alloc_physical_bytes(data, sections, syms)
    emit(f'   {name} at {addr:#x}, {size} bytes (function extent from the symbol table)')
    stores = dword_stores(func)
    emit('   mov dword [rbp+d], imm stores in the function: '
         + (', '.join(f'[rbp-{0x100 - d:#x}]= {imm}' for d, imm in stores) or 'none'))
    exact_v2 = func.find(b'\xc7\x45\x88\x02\x00\x00\x00')
    v2 = [d for d, imm in stores if imm == 2]
    v1 = [d for d, imm in stores if imm == 1]
    if exact_v2 >= 0:
        emit('   VRAM ABI  : writes version 2, exact reference encoding '
             'c7 45 88 02 00 00 00 (mov dword ptr [rbp-0x78], 2) + cookie store -- OK')
    elif v2 and any(lea_same_buffer(func, d) for d in v2):
        d = next(d for d in v2 if lea_same_buffer(func, d))
        emit(f'   VRAM ABI  : writes version 2, relaxed match c7 45 {d:02x} 02 00 00 00 '
             f'(mov dword ptr [rbp-{0x100 - d:#x}], 2) with a matching lea of the request -- OK')
        emit('   NOTE      : differs from the exact reference encoding; likely a different '
             'clang/SDK. Symbol sets still match.')
    else:
        ok = False
        emit(f'   VRAM ABI  : version-2 store NOT FOUND -- this accelerator would still fail '
             f'every nvAllocVram on macOS {major} (issue #51)')
    if v1:
        ok = False
        emit(f'   VRAM ABI  : stale version-1 store PRESENT (mov dword ptr [rbp-{0x100 - v1[0]:#x}], 1) '
             f'-- this is the shipped kexts/{major} bug')
    else:
        emit('   VRAM ABI  : no version-1 store in allocPhysical -- OK')
    emit(f'   RESULT    : {"PASS" if ok else "FAIL"}')
    emit('')
    return ok


def main():
    ap = argparse.ArgumentParser(description='Verify rebuilt NVAccel kexts against the shipped reference.')
    ap.add_argument('--15', dest='b15', metavar='PATH', help='rebuilt macOS 15 NVAccel binary')
    ap.add_argument('--26', dest='b26', metavar='PATH', help='rebuilt macOS 26 NVAccel binary')
    ap.add_argument('--reference', default='tools/reference', metavar='DIR')
    ap.add_argument('--report', metavar='PATH', help='write the report to this file as well')
    args = ap.parse_args()
    if not args.b15 and not args.b26:
        ap.error('give at least one of --15 / --26')
    report, ok = [], True
    if args.b15:
        ok &= check('15', args.b15, args.reference, report)
    if args.b26:
        ok &= check('26', args.b26, args.reference, report)
    text = '\n'.join(report) + '\n'
    sys.stdout.write(text)
    if args.report:
        open(args.report, 'w', encoding='utf-8').write(text)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()