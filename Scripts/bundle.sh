#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./Scripts/bundle.sh [--version <version>] [--sign-identity <identity>] [--output-dir <dir>] [--skip-build]
  ./Scripts/bundle.sh [sign_identity]

Environment:
  APP_NAME            App bundle name (default: Zcreen)
  BUILD_CONFIGURATION swift build configuration (default: release)
  BUILD_DIR           Swift build output directory (default: resolved by SwiftPM)
  UNIVERSAL_BUILD     Set to 1 to build both arm64 and x86_64 (default: 0).
  OUTPUT_DIR          Directory where the .app bundle will be created (default: .)
  SIGN_IDENTITY       Codesign identity. Use "-" for ad-hoc signing (default).
  VERSION             Version to write into the generated app bundle Info.plist.
  SKIP_BUILD          Set to 1 to skip swift build.
EOF
}

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="${APP_NAME:-Zcreen}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-}"
UNIVERSAL_BUILD="${UNIVERSAL_BUILD:-0}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
INFO_PLIST_SOURCE="${INFO_PLIST_SOURCE:-Sources/Zcreen/App/Info.plist}"
ICON_SOURCE="${ICON_SOURCE:-Sources/Zcreen/App/AppIcon.icns}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
VERSION="${VERSION:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:?Missing value for --version}"
            shift 2
            ;;
        --sign-identity)
            SIGN_IDENTITY="${2:?Missing value for --sign-identity}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:?Missing value for --output-dir}"
            shift 2
            ;;
        --build-dir)
            BUILD_DIR="${2:?Missing value for --build-dir}"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD="1"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -z "${SIGN_IDENTITY}" ]]; then
                SIGN_IDENTITY="$1"
                shift
            else
                echo "Unexpected positional argument: $1" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY="-"
fi

APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

build_args=(-c "${BUILD_CONFIGURATION}")
if [[ "${UNIVERSAL_BUILD}" == "1" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi

if [[ "${SKIP_BUILD}" != "1" ]]; then
    echo "==> Building ${BUILD_CONFIGURATION} target..."
    swift build "${build_args[@]}"
fi
if [[ -z "${BUILD_DIR}" ]]; then
    BUILD_DIR="$(swift build "${build_args[@]}" --show-bin-path)"
fi

echo "==> Creating app bundle in ${OUTPUT_DIR}..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}"

cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"

if [[ -f "${ICON_SOURCE}" ]]; then
    cp "${ICON_SOURCE}" "${RESOURCES}/AppIcon.icns"
fi

cp "${INFO_PLIST_SOURCE}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${CONTENTS}/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${CONTENTS}/Info.plist"

if [[ -n "${VERSION}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS}/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "${CONTENTS}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS}/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${VERSION}" "${CONTENTS}/Info.plist"
fi

echo "==> Signing with identity: ${SIGN_IDENTITY}"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --deep --sign - "${APP_BUNDLE}"
else
    codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
fi

echo "==> Done! App bundle: ${APP_BUNDLE}"
echo "    Run: open ${APP_BUNDLE}"
