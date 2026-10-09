#!/bin/sh
# remove-nullmoth.sh -- remove the NullMoth NVIDIA driver from this Mac and rebuild the
# Auxiliary Kernel Collection, so the firmware-framebuffer (software) desktop comes back.
#
# Use when the driver is installed but never produced a working desktop (issue #51) and you
# want the machine back in its pre-install state.
#
#     sudo ./remove-nullmoth.sh
#
# It removes only the driver's own files; a small backup (kexts + kernel collection) is kept
# in /var/tmp/nullmoth-removal-<stamp>/ and the rollback commands are printed at the end.
#
# Why this is needed at all: the driver's NVRMFB.kext has a second personality (NVRMFBClaim,
# probe score 30000) that retires Apple's boot framebuffer (IONDRVFramebuffer, probe 20000)
# as soon as the kext is loaded -- even with the driver "disabled" through boot-args.  So
# disabling through boot-args alone cannot bring the framebuffer desktop back; the kext has
# to stop loading (this script, an OpenCore Kernel->Block entry, or safe mode).
set -eu

EXT=/Library/Extensions
GB=/Library/GPUBundles
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc
KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel
KEXTS="NVRM NVAccel NVRMFB NVRMAGDC"
BUNDLES="NVMTLDriver.bundle NVIDIAShared.bundle nvmtl nvmtl-allow.txt"

step() { echo; echo "== $*"; }
die() { echo "   STOP: $*" >&2; exit 1; }

step "0. checks"
[ "$(id -u)" = 0 ] || die "run this with sudo"
found=0
for k in $KEXTS; do [ -d "$EXT/$k.kext" ] && found=1; done
[ "$found" = 1 ] || die "no NullMoth kexts in $EXT -- nothing to remove"

step "1. back up the driver's files"
BK=$(mktemp -d "/var/tmp/nullmoth-removal-$(date +%Y%m%d-%H%M%S).XXXXXX") || die "create backup dir"
for k in $KEXTS; do [ ! -e "$EXT/$k.kext" ] || ditto "$EXT/$k.kext" "$BK/$k.kext" || die "back up $k"; done
for b in $BUNDLES; do [ ! -e "$GB/$b" ] || ditto "$GB/$b" "$BK/$b" || die "back up $b"; done
[ ! -f "$KC" ] || cp -p "$KC" "$BK/AuxiliaryKernelExtensions.kc" || die "back up the kernel collection"
[ ! -f /Library/NullMoth/os-major ] || cp -p /Library/NullMoth/os-major "$BK/os-major" || true
echo "   backup: $BK"

step "2. remove the driver"
for k in $KEXTS; do rm -rf "$EXT/$k.kext" || die "remove $k"; done
for b in $BUNDLES; do rm -rf "$GB/$b" || die "remove $b"; done
rm -rf /Library/NullMoth || die "remove /Library/NullMoth"
rm -rf /Users/Shared/nvfw || die "remove the GSP firmware"
rm -f /Library/LaunchDaemons/com.nullmoth.recover.plist /Library/LaunchAgents/com.nullmoth.recover.plist 2>/dev/null || true
echo "   driver files gone"

step "3. rebuild the auxiliary kernel collection"
KARG="--allow-missing-kdk"; [ -f "$K" ] && KARG="$KARG --kernel \"$K\""
T=$(mktemp -d /var/tmp/nullmoth-removal-build.XXXX) || die "create the build directory"
NEWKC="$KC.nullmoth-removal-new"; rm -f "$NEWKC"
eval kmutil create -n aux --volume-root / $KARG -B "$KB" -S "$KS" --repository "$EXT" -A "$NEWKC" -z \
  >"$T/kmutil.log" 2>&1 || { tail -20 "$T/kmutil.log"; die "kmutil could not build the collection"; }
[ -s "$NEWKC" ] || die "kmutil produced no collection"
kmutil inspect -a x86_64 -A "$NEWKC" >"$T/inspect.log" 2>&1 || { tail -5 "$T/inspect.log"; die "cannot inspect the new collection"; }
if grep -q 'com\.nullmoth\.' "$T/inspect.log"; then
  grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' "$T/inspect.log" | sort -u
  die "the new collection still names a com.nullmoth kext"
fi
mv -f "$NEWKC" "$KC" || die "publish the new collection"
rm -rf "$T"
echo "   collection rebuilt; no com.nullmoth kext in it"

step "done"
echo "   Reboot now: the framebuffer desktop is back (the state before the driver was installed)."
echo "   With the kexts gone, the OpenCore config no longer needs -x or the NullMoth Kernel->Block"
echo "   entries; the disabled config in EFI/OC works as it is."
echo
echo "   Rollback (puts the driver files back exactly as they were):"
for k in $KEXTS; do [ ! -d "$BK/$k.kext" ] || echo "       sudo ditto '$BK/$k.kext' '$EXT/$k.kext'"; done
for b in $BUNDLES; do [ ! -e "$BK/$b" ] || echo "       sudo ditto '$BK/$b' '$GB/$b'"; done
[ ! -f "$BK/AuxiliaryKernelExtensions.kc" ] || echo "       sudo cp -p '$BK/AuxiliaryKernelExtensions.kc' '$KC'"
echo "       sudo shutdown -r now"