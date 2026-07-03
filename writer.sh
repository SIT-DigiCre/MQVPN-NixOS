#!/usr/bin/env nix-shell
#!nix-shell -i bash -p parted dosfstools util-linux coreutils

set -euo pipefail
TARGET_DEV=$1

if [ -z "$TARGET_DEV" ];then
  echo "Usage: $0 <target_device>"
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

ISO_FILE=$(ls "$(dirname "$0")/result/iso"/*.iso ./result/iso/*.iso 2>/dev/null | head -n1)

if [ -z "$ISO_FILE" ]; then
  echo "Error: ISO file not found"
  echo "Please build the ISO first by running: nix build path:.#nixosConfigurations.iso.config.system.build.isoImage"
  exit 1
fi

RAW_LABEL=$(blkid -s LABEL -o value "$ISO_FILE")

if [ "${#RAW_LABEL}" -gt 11 ]; then
  echo "Error: ISO volume label '$RAW_LABEL' is too long (${#RAW_LABEL} characters)."
  echo "Please reduce the label length by changing 'image.baseName' in configuration.nix to 11 characters or less."
  exit 1
fi

ISO_LABEL=${RAW_LABEL^^}

parted -s "$TARGET_DEV" -- mklabel gpt mkpart primary fat32 1MiB 100% set 1 esp on

partprobe "$TARGET_DEV"
udevadm settle

if [[ "$TARGET_DEV" =~ nvme|mmcblk ]]; then
  PART_DEV="${TARGET_DEV}p1"
else
  PART_DEV="${TARGET_DEV}1"
fi

mkfs.fat -F32 -n "$ISO_LABEL" "$PART_DEV" > /dev/null

MNT_ISO=$(mktemp -d)
MNT_DEV=$(mktemp -d)

cleanup() {
  echo "Cleaning up..."
  umount -q "$MNT_ISO" "$MNT_DEV" || true
  rmdir "$MNT_ISO" "$MNT_DEV"
}
trap cleanup EXIT

mount -o loop,ro "$ISO_FILE" "$MNT_ISO"
mount "$PART_DEV" "$MNT_DEV"

echo "Copying files from ISO to $PART_DEV..."
cp -a "$MNT_ISO"/. "$MNT_DEV"/

echo "Syncing disks..."
sync

