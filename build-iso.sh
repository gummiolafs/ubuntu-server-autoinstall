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
        if [ -f "${OUTPUT_ISO}" ] && [ -s "${OUTPUT_ISO}" ]; then
            info "ISO already present: ${OUTPUT_ISO}"
        else
            info "Downloading ${iso_url}..."
            curl -gL --progress-bar -o "${OUTPUT_ISO}" "${iso_url}"
            if [ ! -s "${OUTPUT_ISO}" ]; then
                error "Download failed or file is empty"
                exit 1
            fi
            info "Download complete"
        fi
    fi
}

extract_and_patch_boot_configs() {
    info "Extracting and patching boot configs..."
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"

    local files_to_extract=(
        "/boot/grub/grub.cfg:${WORK_DIR}/grub.cfg"
        "/boot/grub/loopback.cfg:${WORK_DIR}/loopback.cfg"
    )

    for mapping in "${files_to_extract[@]}"; do
        local iso_path="${mapping%%:*}"
        local disk_path="${mapping##*:}"
        xorriso -osirrox on -indev "${OUTPUT_ISO}" \
            -extract "${iso_path}" "${disk_path}" 2>/dev/null || true
    done

    # Patch GRUB configs
    for cfg in "${WORK_DIR}/grub.cfg" "${WORK_DIR}/loopback.cfg"; do
        if [ -f "${cfg}" ]; then
            info "  Patching $(basename "${cfg}")..."
            perl -pi -e 's#/casper/vmlinuz#/casper/vmlinuz autoinstall ds=nocloud\\;s=/cdrom/#' "${cfg}"
            perl -pi -e 's/set timeout=\d+/set timeout=2/' "${cfg}"
        fi
    done

    # Patch isolinux if present (older ISOs)
    local txt_cfg="${WORK_DIR}/txt.cfg"
    xorriso -osirrox on -indev "${OUTPUT_ISO}" \
        -extract /isolinux/txt.cfg "${txt_cfg}" 2>/dev/null || true
    if [ -f "${txt_cfg}" ]; then
        info "  Patching isolinux/txt.cfg..."
        perl -pi -e 's#(append.*)#$1 autoinstall ds=nocloud\;s=/cdrom/#' "${txt_cfg}"
    fi

    info "Boot configs patched"
}

modify_iso_inplace() {
    info "Modifying ISO in-place (preserving boot configuration)..."

    local xorriso_args=(
        -dev "${OUTPUT_ISO}"
        -boot_image any keep
        -map "${SCRIPT_DIR}/user-data" /user-data
        -map "${SCRIPT_DIR}/meta-data" /meta-data
    )

    if [ -f "${WORK_DIR}/grub.cfg" ]; then
        xorriso_args+=(-map "${WORK_DIR}/grub.cfg" /boot/grub/grub.cfg)
    fi
    if [ -f "${WORK_DIR}/loopback.cfg" ]; then
        xorriso_args+=(-map "${WORK_DIR}/loopback.cfg" /boot/grub/loopback.cfg)
    fi
    if [ -f "${WORK_DIR}/txt.cfg" ]; then
        xorriso_args+=(-map "${WORK_DIR}/txt.cfg" /isolinux/txt.cfg)
    fi

    xorriso_args+=(-commit_eject all "")

    xorriso "${xorriso_args[@]}" 2>&1 | grep -v "^xorriso :" || true

    if [ -s "${OUTPUT_ISO}" ]; then
        info "ISO modified successfully: ${OUTPUT_ISO}"
    else
        error "Failed to modify ISO"
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
