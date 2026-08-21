#!/usr/bin/env bash
# Builds a Movesense firmware app into a DFU package.
#
#   ./Firmware/build.sh moveload_auto_app
#
# Everything runs in Suunto's build container, so nothing (cmake, ninja, the
# ARM toolchain) needs installing on the Mac. The image is x86_64 only, hence
# the explicit platform: on Apple Silicon it runs emulated, which is slower
# but produces the same cross-compiled binary.
#
# SS2_NAND is the Movesense *Flash* sensor. The SDK defaults to SS2, which is
# a different device — building without this flag produces firmware for
# hardware we do not have.
set -euo pipefail

APP="${1:-moveload_auto_app}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/vendor/movesense-device-lib/_build_$APP"

if [ ! -d "$REPO/Firmware/$APP" ]; then
    echo "Pas d'application nommée '$APP' dans Firmware/" >&2
    exit 1
fi

mkdir -p "$BUILD"
docker run --rm --platform linux/amd64 -v "$REPO":/repo -w "/repo/vendor/movesense-device-lib/_build_$APP" \
    movesense/sensor-build-env:2.2 bash -c "
        cmake -G Ninja \
            -DMOVESENSE_CORE_LIBRARY=../MovesenseCoreLib/ \
            -DCMAKE_TOOLCHAIN_FILE=../MovesenseCoreLib/toolchain/gcc-nrf52.cmake \
            -DHWCONFIG=SS2_NAND \
            /repo/Firmware/$APP && ninja pkgs"

echo
echo "Paquet DFU : $BUILD/Movesense_dfu.zip"
echo "Retour au firmware d'origine si besoin :"
echo "  vendor/movesense-device-lib/samples/bin/release/default_firmware/Movesense-default_firmware-SS2_NAND_w_bootloader.zip"
