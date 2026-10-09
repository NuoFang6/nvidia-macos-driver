Symbol tables extracted from the official nullmoth-nvidia-1.1.0.tar.gz payload
(release v1.1.1) with a read-only Mach-O nlist parser (tools/verify_accel.py):

  Library/NullMoth/kexts/15/NVAccel.kext/Contents/MacOS/NVAccel
      sha256 cac6763c075aa2a1ed5ebbd74b1fe9a20a9de546086ef054e6feea58ec1e3cc8
      imports 868   exports 333
  Library/NullMoth/kexts/26/NVAccel.kext/Contents/MacOS/NVAccel
      sha256 5aee66f533f48ce84366fd2f63b30e9f7dea35ad25b1b0974e3d34a0b829442b
      imports 843   exports 401

The macOS 26 file is the stale build described in issue #51 (it writes VRAM ABI
version 1 into a 0x70-byte NVRMVramRequest); its import/export tables match a
rebuild from the 1.1 sources verified by PR #60, so they serve as the equivalence
reference for CI builds.  Reference encodings for NVVidMemory::allocPhysical:

  shipped 15, ABI 2 (correct):  c7 45 88 02 00 00 00  = mov dword ptr [rbp-0x78], 2
                                then 4c 89 7d 90     = mov qword ptr [rbp-0x70], r15 (allocationCookie)
  shipped 26, ABI 1 (broken):   c7 45 90 01 00 00 00  = mov dword ptr [rbp-0x70], 1

Each file lists one entry per symbol: "IMPORT <name>" / "EXPORT <name>", sorted.