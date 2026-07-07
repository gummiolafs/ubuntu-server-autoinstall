#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/.work"
OUTPUT_ISO="${SCRIPT_DIR}/ubuntu-autoinstall.iso"
UBUNTU_VERSION="26.04"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_dependencies() {
    local missing=()
    command -v xorriso &>/dev/null || missing+=(xorriso)
    command -v curl   &>/dev/null || missing+=(curl)
    command -v perl   &>/dev/null || missing+=(perl)
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with Homebrew:"
        echo "  brew install xorriso perl"
        exit 1
    fi
}

find_latest_iso_url() {
    local version="$1"
    local releases_url="https://releases.ubuntu.com/${version}/"
    info "Finding latest Ubuntu ${version} Server ISO..."
    local iso_filename
    iso_filename=$(curl -gsL "${releases_url}" \
        | grep -oE "ubuntu-[0-9.]+(\.[0-9]+)?-live-server-amd64\.iso" \
        | sort -V | tail -1)
    if [ -z "${iso_filename}" ]; then
        error "Could not find ISO filename at ${releases_url}"
        exit 1
    fi
    echo "${releases_url}${iso_filename}"
}

prepare_iso() {
    if [ $# -ge 1 ] && [ -f "$1" ]; then
        info "Copying provided ISO to output path..."
        cp "$1" "${OUTPUT_ISO}"
    else
        local iso_url
        iso_url=$(find_latest_iso_url "${UBUNTU_VERSION}")
        if [ -f "${SCRIPT_DIR}/ubuntu-server.iso" ] && [ -s "${SCRIPT_DIR}/ubuntu-server.iso" ]; then
            info "ISO already present: ${SCRIPT_DIR}/ubuntu-server.iso"
            cp "${SCRIPT_DIR}/ubuntu-server.iso" "${OUTPUT_ISO}"
        else
            info "Downloading ${iso_url}..."
            curl -gL --progress-bar -o "${SCRIPT_DIR}/ubuntu-server.iso" "${iso_url}"
            if [ ! -s "${SCRIPT_DIR}/ubuntu-server.iso" ]; then
                error "Download failed or file is empty"
                exit 1
            fi
            cp "${SCRIPT_DIR}/ubuntu-server.iso" "${OUTPUT_ISO}"
            info "Download complete"
        fi
    fi
}


extract_and_patch_boot_configs() {
    info "Extracting ISO to workspace..."
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}/iso"

    # Extract all
    xorriso -osirrox on -indev "${OUTPUT_ISO}" -extract / "${WORK_DIR}/iso" 2>/dev/null || true
    chmod -R u+w "${WORK_DIR}/iso"

    # Setup nocloud
    info "Setting up autoinstall configs..."
    mkdir -p "${WORK_DIR}/iso/nocloud"
    cp "${SCRIPT_DIR}/user-data" "${WORK_DIR}/iso/nocloud/"
    cp "${SCRIPT_DIR}/meta-data" "${WORK_DIR}/iso/nocloud/"
    # For subiquity safety, also place at root
    cp "${SCRIPT_DIR}/user-data" "${WORK_DIR}/iso/"
    cp "${SCRIPT_DIR}/meta-data" "${WORK_DIR}/iso/"

    # Patch GRUB configs
    for cfg in "${WORK_DIR}/iso/boot/grub/grub.cfg" "${WORK_DIR}/iso/boot/grub/loopback.cfg"; do
        if [ -f "${cfg}" ]; then
            info "  Patching $(basename "${cfg}")..."
            perl -pi -e 's#(linux.*?)(\s+---\s.*|$)#$1 autoinstall ds="nocloud;s=/cdrom/nocloud/" console=ttyS0$2#' "${cfg}"
            perl -pi -e 's/set timeout=\d+/set timeout=2/' "${cfg}"
        fi
    done

    # Patch isolinux if present (older ISOs)
    local txt_cfg="${WORK_DIR}/iso/isolinux/txt.cfg"
    if [ -f "${txt_cfg}" ]; then
        info "  Patching isolinux/txt.cfg..."
        perl -pi -e 's#(append.*)#$1 autoinstall ds="nocloud;s=/cdrom/nocloud/" console=ttyS0#' "${txt_cfg}"
    fi

    info "Boot configs patched"
}

modify_iso_inplace() {
    info "Packaging custom ISO..."
    
    local UUID
    UUID=$(date +%Y-%m-%d-%H-%M-%S-00 | sed 's/-//g')

    # Ensure efi.img is available. If ISO extraction misses the hidden El-Torito EFI image,
    # generate a fallback or extract it dynamically.
    if [ ! -f "${WORK_DIR}/iso/efi.img" ]; then
        info "Extracting hidden EFI image..."
        local efistart
        efistart=$(xorriso -indev "${SCRIPT_DIR}/ubuntu-server.iso" -report_el_torito as_mkisofs 2>/dev/null | grep -oE "\-e [^ ]+" | awk '{print $2}' || true)
        if [[ "$efistart" == *"appended_partition"* ]]; then
            # Extract UEFI Boot Partition (El Torito)
            xorriso -osirrox on -indev "${SCRIPT_DIR}/ubuntu-server.iso" -extract_boot_images "${WORK_DIR}/iso" 2>/dev/null || true
            # xorriso saves appended_partition_X as eltorito_imgX_fs.img
            for img in "${WORK_DIR}/iso"/eltorito_img*.img; do
                 if [ -f "$img" ]; then
                      mv "$img" "${WORK_DIR}/iso/efi.img"
                      break
                 fi
            done
        fi
    fi

    xorriso -as mkisofs -r \
      -V "Ubuntu-Server26.04" \
      -J -l -b boot/grub/i386-pc/eltorito.img \
      -c boot.catalog \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      -eltorito-alt-boot \
      -e efi.img \
      -no-emul-boot -isohybrid-gpt-basdat -isohybrid-apm-hfsplus \
      -o "${OUTPUT_ISO}" \
      "${WORK_DIR}/iso" 2>/dev/null

    if [ -s "${OUTPUT_ISO}" ]; then
        info "ISO packaged successfully: ${OUTPUT_ISO}"
    else
        error "Failed to package ISO"
        exit 1
    fi
}

print_usage_instructions() {
    local iso_size
    iso_size=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
    echo ""
    echo "========================================"
    echo "  Build Complete!"
    echo "========================================"
    echo "  Output:  ${OUTPUT_ISO} (${iso_size})"
    echo ""
    echo "  Write to USB (macOS):"
    echo "    1. Insert USB drive"
    echo "    2. diskutil list                  # find your USB (e.g., disk4)"
    echo "    3. diskutil unmountDisk /dev/disk4"
    echo "    4. sudo dd if=${OUTPUT_ISO} of=/dev/rdisk4 bs=4m"
    echo "    5. diskutil eject /dev/disk4"
    echo ""
    echo "  Boot from USB on target PC."
    echo "  Installation runs automatically (2s timeout to interrupt)."
    echo "  Login via SSH:  ssh gummiolafs@<host-ip>"
    echo "  Password (console): changeme"
    echo "========================================"
}

main() {
    check_dependencies
    mkdir -p "${WORK_DIR}"

    prepare_iso "$@"
    extract_and_patch_boot_configs
    modify_iso_inplace
    print_usage_instructions
}

main "$@"
