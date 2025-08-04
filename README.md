# USB Nuke Beast

**The ultimate Linux script to wipe, encrypt, format, and mount USB drives – safely and interactively.**

 this tool lets you **zero or shred** your device, optionally **encrypt** with LUKS, **partition**, **format** (ext4, exFAT, FAT32, NTFS), and **mount** it — all in a clean Bash CLI interface.

---

## Features

- Full USB wipe: `dd` or `shred`
- Optional partitioning: GPT or MBR
- Create full partition
- Set custom partition label
- Optional LUKS encryption
- Format as ext4, exFAT, FAT32, or NTFS
- Optional mount with directory name
- Safety confirmations for all operations
- Clean colored CLI output

---

## Requirements

Install necessary packages:

```bash
sudo apt install parted cryptsetup exfatprogs dosfstools ntfs-3g
