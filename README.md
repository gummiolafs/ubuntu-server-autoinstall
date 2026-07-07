# Ubuntu Server Autoinstall

Creates a bootable USB ISO that installs Ubuntu Server LTS automatically — no prompts, no interaction needed. Just boot from the USB and walk away.

## What it does

- Downloads the latest Ubuntu Server LTS ISO (currently 26.04)
- Injects a `cloud-init` autoinstall config (`user-data`) into the ISO
- Patches GRUB to boot with `autoinstall ds=nocloud;s=/cdrom/` (2s timeout to interrupt)
- Modifies the ISO **in-place** — no extraction/repack needed, minimal disk space required
- Produces `ubuntu-autoinstall.iso`, ready to `dd` onto a USB drive

## Autoinstall configuration

| Setting | Value |
|---|---|
| Ubuntu version | 26.04 LTS |
| Locale | `is_IS.UTF-8` |
| Keyboard | Icelandic (`is`) |
| Timezone | `Atlantic/Reykjavik` |
| Storage | Wipes largest disk, GPT, 512M EFI + ext4 root (no encryption, no LVM) |
| Users | `gummiolafs` (sudo) and `hermes` (sudo) |
| SSH | Server installed, password auth disabled, SSH keys registered |
| Sudo | Passwordless for all sudo users |
| Packages | `qemu-guest-agent` |

### Users

**gummiolafs**
- Password: `changeme` (change on first login with `passwd`)
- SSH key: `~/.ssh/id_rsa.pub` (RSA)

**hermes**
- No password set (SSH key only)
- SSH key: ed25519 from `hermes@proxmox.g87.is`

## Prerequisites

```bash
brew install xorriso perl
```

## Build the ISO

```bash
./build-iso.sh
```

Or provide your own ISO:
```bash
./build-iso.sh /path/to/ubuntu-26.04-live-server-amd64.iso
```

## Write to USB (macOS)

```bash
diskutil list                    # find your USB, e.g. disk4
diskutil unmountDisk /dev/disk4
sudo dd if=ubuntu-autoinstall.iso of=/dev/rdisk4 bs=4m
diskutil eject /dev/disk4
```

## Use

1. Insert USB into target PC
2. Boot from USB
3. Installation runs automatically (2s GRUB timeout to interrupt)
4. After install, SSH in:
   ```bash
   ssh gummiolafs@<host-ip>
   ```
5. Change the password on first login:
   ```bash
   passwd
   ```

## Files

| File | Description |
|---|---|
| `build-iso.sh` | Downloads, patches, and modifies the ISO in-place |
| `user-data` | Cloud-init autoinstall config (users, storage, SSH, packages) |
| `meta-data` | NoCloud datasource metadata |
| `.gitignore` | Ignores `.work/` and `*.iso` build artifacts |

## Customization

Edit `user-data` to change:
- Username/password (regenerate the hash with `mkpasswd -m sha-512` or `python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.hash('yourpass'))"`)
- SSH keys
- Storage layout
- Locale/keyboard/timezone
- Packages to install

## Notes

- The autoinstall config uses `wipe: superblock-recursive` — this **destroys all data** on the largest disk. Don't boot this USB on a machine with data you want to keep.
- The ISO modifies the original Ubuntu ISO in-place using `xorriso -dev` which preserves the original boot configuration (El Torito, MBR, GPT, EFI image).
- The `user-data` password hash is for `changeme` — change it before building if needed.
