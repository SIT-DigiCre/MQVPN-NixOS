#!/usr/bin/env nix-shell
#!nix-shell -i bash -p parted dosfstools util-linux coreutils

set -e
TARGET_DEV=$1

if [ -z "$TARGET_DEV" ];then
  echo "Usage: $0 <target_device>"
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

ISO_FILE="$(dirname "$0")/result/iso/mqvpn-router.iso"
if [ ! -f "$ISO_FILE" ]; then
  ISO_FILE="./result/iso/mqvpn-router.iso"
fi

if [ ! -f "$ISO_FILE" ]; then
  echo "Error: ISO file not found at $ISO_FILE"
  echo "Please build the ISO first by running: nix build path:.#nixosConfigurations.iso.config.system.build.isoImage"
  exit 1
fi

ISO_LABEL=$(blkid -s LABEL -o value "$ISO_FILE" | cut -c 1-11 | tr '[:lower:]' '[:upper:]')
if [ -z "$ISO_LABEL" ]; then
  ISO_LABEL="BOOT_ISO"
fi

parted -s "$TARGET_DEV" mklabel gpt
parted -s "$TARGET_DEV" mkpart primary fat32 1MiB 100%
parted -s "$TARGET_DEV" set 1 esp on

sudo env "PATH=$PATH" partprobe "$TARGET_DEV"
sleep 3

if [[ "$TARGET_DEV" =~ nvme|mmcblk ]]; then
    PART_DEV="${TARGET_DEV}p1"
else
    PART_DEV="${TARGET_DEV}1"
fi

sleep 2

mkfs.fat -F32 -n "$ISO_LABEL" "$PART_DEV" > /dev/null

MNT_ISO=$(mktemp -d)
MNT_DEV=$(mktemp -d)

mount -o loop "$ISO_FILE" "$MNT_ISO"
mount "$PART_DEV" "$MNT_DEV"

cp -a "$MNT_ISO"/* "$MNT_DEV"/

sync
umount "$MNT_ISO" "$MNT_DEV"
rmdir "$MNT_ISO" "$MNT_DEV"

