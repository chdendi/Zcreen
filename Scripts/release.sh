#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./Scripts/release.sh <version>
  ./Scripts/release.sh --version <version> [--artifact-dir <dir>] [--sign-identity <identity>]

Local configuration:
  Optional .env.local values:
    SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
    NOTARIZE_PROFILE="Zcreen"

CI configuration:
  Provide these environment variables instead of .env.local:
    SIGN_IDENTITY
    APPLE_ID
    APPLE_TEAM_ID
    APPLE_APP_SPECIFIC_PASSWORD

Notes:
  - Uses ad-hoc signing when SIGN_IDENTITY is omitted.
  - Writes all release artifacts into ARTIFACT_DIR (default: dist).
EOF
}

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="${APP_NAME:-Zcreen}"
ARTIFACT_DIR="${ARTIFACT_DIR:-dist}"
SOURCE_ENV_FILE="${SOURCE_ENV_FILE:-.env.local}"
VERSION="${RELEASE_VERSION:-${VERSION:-}}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"
APPLE_ID="${APPLE_ID:-${NOTARIZE_APPLE_ID:-}}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-${NOTARIZE_TEAM_ID:-}}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${NOTARIZE_PASSWORD:-}}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"

if [[ -f "${SOURCE_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${SOURCE_ENV_FILE}"
fi

APPLE_ID="${APPLE_ID:-${NOTARIZE_APPLE_ID:-}}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-${NOTARIZE_TEAM_ID:-}}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${NOTARIZE_PASSWORD:-}}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:?Missing value for --version}"
            shift 2
            ;;
        --artifact-dir)
            ARTIFACT_DIR="${2:?Missing value for --artifact-dir}"
            shift 2
            ;;
        --sign-identity)
            SIGN_IDENTITY="${2:?Missing value for --sign-identity}"
            shift 2
            ;;
        --notarize-profile)
            NOTARIZE_PROFILE="${2:?Missing value for --notarize-profile}"
            shift 2
            ;;
        --apple-id)
            APPLE_ID="${2:?Missing value for --apple-id}"
            shift 2
            ;;
        --team-id)
            APPLE_TEAM_ID="${2:?Missing value for --team-id}"
            shift 2
            ;;
        --app-password)
            APPLE_APP_SPECIFIC_PASSWORD="${2:?Missing value for --app-password}"
            shift 2
            ;;
        --skip-notarization)
            SKIP_NOTARIZATION="1"
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
            if [[ -z "${VERSION}" ]]; then
                VERSION="$1"
                shift
            else
                echo "Unexpected positional argument: $1" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    usage >&2
    exit 1
fi

if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY="-"
fi

APP_BUNDLE="${ARTIFACT_DIR}/${APP_NAME}.app"
ZIP_NAME="${ARTIFACT_DIR}/${APP_NAME}-v${VERSION}.zip"
DMG_NAME="${ARTIFACT_DIR}/${APP_NAME}-v${VERSION}.dmg"

notarytool_args=()
if [[ "${SKIP_NOTARIZATION}" == "1" ]]; then
    echo "==> Skipping notarization (SKIP_NOTARIZATION=1)"
elif [[ -n "${NOTARIZE_PROFILE}" ]]; then
    notarytool_args=(--keychain-profile "${NOTARIZE_PROFILE}")
elif [[ -n "${APPLE_ID}" && -n "${APPLE_TEAM_ID}" && -n "${APPLE_APP_SPECIFIC_PASSWORD}" ]]; then
    notarytool_args=(
        --apple-id "${APPLE_ID}"
        --team-id "${APPLE_TEAM_ID}"
        --password "${APPLE_APP_SPECIFIC_PASSWORD}"
    )
else
    echo "==> Skipping notarization (no NOTARIZE_PROFILE or Apple notary credentials configured)"
fi

submit_for_notarization() {
    local target="$1"

    if [[ ${#notarytool_args[@]} -eq 0 ]]; then
        return 0
    fi

    xcrun notarytool submit "${target}" "${notarytool_args[@]}" --wait
}

echo "==> Release: ${APP_NAME} v${VERSION}"
echo "    Identity: ${SIGN_IDENTITY}"
echo "    Artifacts: ${ARTIFACT_DIR}"

mkdir -p "${ARTIFACT_DIR}"
rm -rf "${APP_BUNDLE}" "${ZIP_NAME}" "${DMG_NAME}"

echo "==> Building app bundle..."
UNIVERSAL_BUILD=1 bash Scripts/bundle.sh \
    --version "${VERSION}" \
    --sign-identity "${SIGN_IDENTITY}" \
    --output-dir "${ARTIFACT_DIR}"

echo "==> Creating ${ZIP_NAME}..."
ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_NAME}"

if [[ ${#notarytool_args[@]} -gt 0 ]]; then
    echo "==> Notarizing ${ZIP_NAME}..."
    submit_for_notarization "${ZIP_NAME}"
    echo "==> Stapling ${APP_BUNDLE}..."
    xcrun stapler staple "${APP_BUNDLE}"
    rm -f "${ZIP_NAME}"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_NAME}"
fi

echo "==> Creating ${DMG_NAME}..."
DMG_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.release.XXXXXX")"
trap 'rm -rf "${DMG_TEMP}"' EXIT
cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_NAME}" >/dev/null

if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_NAME}"
fi

if [[ ${#notarytool_args[@]} -gt 0 ]]; then
    echo "==> Notarizing ${DMG_NAME}..."
    submit_for_notarization "${DMG_NAME}"
    xcrun stapler staple "${DMG_NAME}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "version=${VERSION}"
        echo "zip_path=${ZIP_NAME}"
        echo "dmg_path=${DMG_NAME}"
    } >> "${GITHUB_OUTPUT}"
fi

echo ""
echo "==> Release artifacts ready:"
echo "    ${ZIP_NAME}"
echo "    ${DMG_NAME}"
echo ""
echo "Next steps:"
echo "  1. git tag v${VERSION}"
echo "  2. git push origin v${VERSION}"
echo "  3. Let .github/workflows/release.yml publish the artifacts"
