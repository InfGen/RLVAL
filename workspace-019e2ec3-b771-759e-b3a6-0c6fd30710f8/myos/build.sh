#!/usr/bin/env bash
# Build script for MyOS.
# Produces: boot.bin, kernel.bin, rlval.img (a 1.44 MB floppy image).
#
# Requires: nasm
#
# Usage:
#   ./build.sh          - build everything
#   ./build.sh run      - build and run in QEMU
#   ./build.sh clean    - remove build artifacts

set -e
cd "$(dirname "$0")"

case "${1:-build}" in
  clean)
    rm -f boot.bin kernel.bin rlval.img
    echo "Cleaned."
    exit 0
    ;;
esac

echo "[1/3] Assembling boot.asm -> boot.bin"
nasm -f bin boot.asm -o boot.bin

echo "[2/3] Assembling kernel.asm -> kernel.bin"
nasm -f bin kernel.asm -o kernel.bin

echo "[3/3] Building rlval.img (1.44 MB floppy)"
# Create a 1.44 MB blank floppy image.
dd if=/dev/zero of=rlval.img bs=512 count=2880 status=none
# Place boot sector at sector 0 (offset 0).
dd if=boot.bin of=rlval.img conv=notrunc status=none
# Place kernel at sector 1 (offset 512).  bs=512 seek=1 puts it at sector 2 LBA=1.
dd if=kernel.bin of=rlval.img bs=512 seek=1 conv=notrunc status=none

echo
echo "Build complete:"
ls -la boot.bin kernel.bin rlval.img

if [ "${1:-}" = "run" ]; then
  echo
  echo "Launching QEMU..."
  qemu-system-i386 -fda rlval.img -boot a
fi
