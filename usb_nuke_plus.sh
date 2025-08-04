#!/bin/bash

# USB Nuke Beast v1.0
# Author: HACKER_BRAIN
# A complete wipe, encrypt, format, and mount tool for USB devices
# Secure USB wipe, encrypt, partition, format, mount — all in Bash

echo -e "
${RED}     ____  __    _   _            ____                     _     
    |  _ \\|  \\  | | | | ___  ___ | __ )  ___  ___  ___ ___| |__  
    | | | | |\\/ | |_| |/ _ \\/ _ \\|  _ \\ / _ \\/ __|/ __/ _ \\ '_ \\ 
    | |_| | |  | |  _  |  __/ (_) | |_) |  __/\\__ \\ (_|  __/ |_) |
    |____/|_|  |_|_| |_|\\___|\\___/|____/ \\___||___/\\___\\___|_.__/ 
            ${YELLOW}USB NUKE BEAST — All-In-One USB Toolkit${RESET}
"
# ==== Colors ====
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
RESET="\033[0m"

echo -e "${BLUE}Available Disks:${RESET}"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL | grep -v "loop"

echo ""
read -p "Enter the device path to nuke (e.g., /dev/sdX): " DEVICE
if [ -z "$DEVICE" ] || [ ! -b "$DEVICE" ]; then
  echo -e "${RED}Invalid device. Aborting.${RESET}"
  exit 1
fi

echo -e "${YELLOW}WARNING: ALL DATA ON $DEVICE WILL BE DESTROYED!${RESET}"
read -p "Type 'NUKE' to confirm: " confirm
[[ "$confirm" != "NUKE" ]] && echo -e "${RED}Aborted.${RESET}" && exit 1

echo ""
echo -e "${CYAN}Choose wipe method:${RESET}"
echo "1) Zero fill"
echo "2) Shred (secure wipe)"
read -p "Select (1/2 or Enter to skip): " WIPE_METHOD

if [ "$WIPE_METHOD" = "1" ]; then
  echo -e "${GREEN}Starting zero wipe...${RESET}"
  sudo dd if=/dev/zero of="$DEVICE" bs=4M status=progress conv=fsync
elif [ "$WIPE_METHOD" = "2" ]; then
  echo -e "${GREEN}Starting shred...${RESET}"
  sudo shred -v -n 1 -z "$DEVICE"
else
  echo -e "${YELLOW}Skipping wipe.${RESET}"
fi

echo ""
echo -e "${CYAN}Choose partition table:${RESET}"
echo "1) GPT"
echo "2) MBR"
read -p "Select (1/2 or Enter to skip): " PT_TYPE

if [[ "$PT_TYPE" == "1" ]]; then
  sudo parted "$DEVICE" --script mklabel gpt
  echo -e "${GREEN}GPT label set.${RESET}"
elif [[ "$PT_TYPE" == "2" ]]; then
  sudo parted "$DEVICE" --script mklabel msdos
  echo -e "${GREEN}MBR label set.${RESET}"
else
  echo -e "${YELLOW}Skipping partition table setup.${RESET}"
fi

read -p "Create one full-size partition? (y/n): " create_part
if [[ "$create_part" =~ ^[Yy]$ ]]; then
  sudo parted "$DEVICE" --script mkpart primary 1MiB 100%
  PART="${DEVICE}1"
  echo -e "${GREEN}Partition created: $PART${RESET}"
else
  echo -e "${YELLOW}Skipping partition creation.${RESET}"
  PART="${DEVICE}1"
fi

read -p "Enter label for the partition (e.g., MYDISK): " LABEL
[[ -z "$LABEL" ]] && LABEL="MYDISK"

read -p "Encrypt with LUKS? (y/n): " do_encrypt
if [[ "$do_encrypt" =~ ^[Yy]$ ]]; then
  echo -e "${BLUE}Encrypting...${RESET}"
  sudo cryptsetup luksFormat "$PART"
  sudo cryptsetup open "$PART" secureusb
  MAPPED_DEV="/dev/mapper/secureusb"
else
  MAPPED_DEV="$PART"
fi

echo ""
echo -e "${CYAN}Choose filesystem:${RESET}"
echo "1) ext4"
echo "2) exFAT"
echo "3) FAT32"
echo "4) NTFS"
read -p "Select (1-4 or Enter to skip): " FSTYPE

case "$FSTYPE" in
  1) sudo mkfs.ext4 -L "$LABEL" "$MAPPED_DEV" ;;
  2) sudo mkfs.exfat -n "$LABEL" "$MAPPED_DEV" ;;
  3) sudo mkfs.vfat -F 32 -n "$LABEL" "$MAPPED_DEV" ;;
  4) sudo mkfs.ntfs -f -L "$LABEL" "$MAPPED_DEV" ;;
  *) echo -e "${YELLOW}Skipping formatting.${RESET}" ;;
esac

read -p "Mount now? (y/n): " do_mount
if [[ "$do_mount" =~ ^[Yy]$ ]]; then
  read -p "Enter mount directory name (default: usb): " MOUNT_NAME
  [[ -z "$MOUNT_NAME" ]] && MOUNT_NAME="usb"
  MOUNT_DIR="/mnt/$MOUNT_NAME"
  sudo mkdir -p "$MOUNT_DIR"
  sudo mount "$MAPPED_DEV" "$MOUNT_DIR"
  sudo chown -R "$USER:$USER" "$MOUNT_DIR"
  echo -e "${GREEN}Mounted at $MOUNT_DIR${RESET}"
fi

echo ""
echo -e "${GREEN}DONE: All operations completed.${RESET}"
