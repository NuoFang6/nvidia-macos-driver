#!/bin/sh
# install-nvaccel26.sh -- replace the NVAccel accelerator with the rebuilt VRAM-ABI-2
# kext and rebuild the Auxiliary Kernel Collection.  Fix for issue #51:
# "macOS 26 (Tahoe), driver 1.1.0: black desktop because kexts/26/NVAccel.kext still
#  speaks VRAM ABI 1 while NVRMFB speaks 2".
#
# Run on the Mac, as root, next to a directory holding the rebuilt kext:
#     sudo ./install-nvaccel26.sh ./NVAccel-abi2-macos26/NVAccel.kext
# or with the default layout produced by the CI artifact:
#     sudo ./install-nvaccel26.sh
#
# What it changes (nothing else):
#     /Library/Extensions/NVAccel.kext                      (the live kext)
#     /Library/NullMoth/kexts/26/NVAccel.kext               (the cached per-OS copy)
#     /Library/KernelCollections/AuxiliaryKernelExtensions.kc (rebuilt)
# Backups go to /Library/NullMoth/backup-nvaccel-abi2-<stamp>/ ; the script prints
# the exact rollback commands at the end.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=${1:-"$HERE/NVAccel-abi2-macos26/NVAccel.kext"}
EXT=/Library/Extensions/NVAccel.kext
CACHE=/Library/NullMoth/kexts/26/NVAccel.kext
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc
KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel

step() { echo; echo "== $*"; }
die() { echo "   STOP: $*" >&2; exit 1; }

step "0. checks"
[ "$(id -u)" = 0 ] || die "run this with sudo"
[ -d "$PAYLOAD" ] && [ -f "$PAYLOAD/Contents/MacOS/NVAccel" ] && [ -f "$PAYLOAD/Contents/Info.plist" ] \
  || die "no complete NVAccel.kext at '$PAYLOAD' (pass its path as the first argument)"
V=$(sw_vers -productVersion); MAJ=${V%%.*}
[ "$MAJ" = 26 ] || echo "   WARNING: this payload is the macOS 26 build; you are on $V"
[ -d "$EXT" ] || die "no driver installed at $EXT -- install the official nullmoth-nvidia package first"
[ -d "$CACHE" ] || die "no cached accelerator at $CACHE -- is this a macOS 26 install?"
if [ -f "$HERE/SHA256SUMS" ]; then
  (cd "$HERE" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS check failed for the payload"
  echo "   payload checksums OK"
fi

step "1. back up the current accelerator"
BK=$(mktemp -d "/Library/NullMoth/backup-nvaccel-abi2-$(date +%Y%m%d-%H%M%S).XXXXXX") || die "create backup dir"
ditto "$EXT" "$BK/NVAccel.kext-Extensions" || die "back up $EXT"
ditto "$CACHE" "$BK/NVAccel.kext-cache26" || die "back up $CACHE"
[ ! -f "$KC" ] || cp -p "$KC" "$BK/AuxiliaryKernelExtensions.kc" || die "back up the kernel collection"
echo "   backup: $BK"

restore() {
  echo "   restoring the previous accelerator..."
  ditto "$BK/NVAccel.kext-Extensions" "$EXT" || true
  ditto "$BK/NVAccel.kext-cache26" "$CACHE" || true
  [ ! -f "$BK/AuxiliaryKernelExtensions.kc" ] || cp -p "$BK/AuxiliaryKernelExtensions.kc" "$KC" || true
}
trap 'echo "   STOP: failed -- running rollback" >&2; restore' EXIT INT TERM

step "2. install the rebuilt accelerator"
ditto "$PAYLOAD/Contents/MacOS/NVAccel" "$EXT/Contents/MacOS/NVAccel" || die "copy the live executable"
ditto "$PAYLOAD/Contents/Info.plist" "$EXT/Contents/Info.plist" || die "copy the live Info.plist"
ditto "$PAYLOAD/Contents/MacOS/NVAccel" "$CACHE/Contents/MacOS/NVAccel" || die "copy the cached executable"
ditto "$PAYLOAD/Contents/Info.plist" "$CACHE/Contents/Info.plist" || die "copy the cached Info.plist"
chown -R root:wheel "$EXT" "$CACHE" || die "fix ownership"
chmod -R go-w "$EXT" "$CACHE" || die "fix permissions"
(cd "$CACHE/.." && find NVAccel.kext -type f -exec shasum -a 256 '{}' \;) > "$CACHE/../SHA256SUMS" || die "refresh the cache manifest"
(cd "$EXT/.." && shasum -a 256 NVAccel.kext/Contents/MacOS/NVAccel) > "$EXT/../NVAccel-SHA256SUMS" || true
echo "   installed"

step "3. rebuild the auxiliary kernel collection"
NEWKC="$KC.nvaccel-abi2-new"; T=$(mktemp -d /var/tmp/nullmoth-abi2.XXXX) || die "create the preflight directory"
KARG="--allow-missing-kdk"; [ -f "$K" ] && KARG="$KARG --kernel \"$K\""
eval kmutil create -n aux --volume-root / $KARG -B "$KB" -S "$KS" --repository "$EXT" -A "$NEWKC" -z \
  >"$T/kmutil.log" 2>&1 || { tail -20 "$T/kmutil.log"; die "kmutil could not build the collection"; }
[ -s "$NEWKC" ] || die "kmutil produced no collection"
kmutil inspect -a x86_64 -A "$NEWKC" >"$T/inspect.log" 2>&1 || { tail -5 "$T/inspect.log"; die "cannot inspect the new collection"; }
for k in NVRM NVAccel NVRMFB NVRMAGDC; do
  grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' "$T/inspect.log" | grep -Fxq "com.nullmoth.$k" \
    || { tail -20 "$T/kmutil.log"; die "com.nullmoth.$k missing from the new collection"; }
done
mv -f "$NEWKC" "$KC" || die "publish the new collection"
rm -rf "$T"
echo "   collection rebuilt with com.nullmoth.NVAccel from this payload"

trap - EXIT INT TERM
step "done"
echo "   Next:"
echo "   1) Make sure the EFI config runs the driver again (nvfb=1 nvaccel=1 nvfbheads=4,"
echo "      -nvkmsnosmooth + the amfi boot-args + the IONDRVSupport Kernel->Block entry;"
echo "      on this setup: restore config.plist from config.plist.nullmoth-driver-20261010)."
echo "   2) sudo shutdown -r now"
echo "   3) After the reboot check:"
echo "        kmutil showloaded --list-only | grep nullmoth        # 4 lines"
echo "        system_profiler SPDisplaysDataType | head -20        # display online, Metal 3"
echo "        log show --last boot | grep -c 'ABI mismatch'        # 0"
echo
echo "   Rollback (restores the files this script replaced):"
echo "        sudo ditto '$BK/NVAccel.kext-Extensions' '$EXT'"
echo "        sudo ditto '$BK/NVAccel.kext-cache26' '$CACHE'"
[ ! -f "$BK/AuxiliaryKernelExtensions.kc" ] || echo "        sudo cp -p '$BK/AuxiliaryKernelExtensions.kc' '$KC'"
echo "        sudo shutdown -r now"