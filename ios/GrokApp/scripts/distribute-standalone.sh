#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${IOS_ROOT}/../.." && pwd)"
PROJECT_PATH="${IOS_ROOT}/GrokApp.xcodeproj"
SCHEME="GrokApp"

TEAM_ID="${APPLE_TEAM_ID:-8NN27Z7TQR}"
METHOD="app-store-connect"
DESTINATION="export"
BUILD_NUMBER="${IOS_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
OUTPUT_DIR="${IOS_DISTRIBUTION_DIR:-${REPO_ROOT}/build/ios-distribution}"
ARCHIVE_PATH=""

usage() {
  printf '%s\n' \
    "Build a signed iOS archive for installation without Xcode." \
    "" \
    "Usage:" \
    "  $(basename "$0") [options]" \
    "" \
    "Options:" \
    "  --upload                 Upload the archive to App Store Connect/TestFlight." \
    "  --method METHOD          app-store-connect (default), release-testing, or debugging." \
    "  --team-id TEAM_ID        Apple Developer team. Defaults to APPLE_TEAM_ID or ${TEAM_ID}." \
    "  --build-number NUMBER    CFBundleVersion. Defaults to IOS_BUILD_NUMBER or a timestamp." \
    "  --output-dir PATH        Archive/export directory. Defaults to build/ios-distribution." \
    "  -h, --help               Show this help." \
    "" \
    "Examples:" \
    "  $(basename "$0") --upload" \
    "  $(basename "$0") --method release-testing"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload)
      DESTINATION="upload"
      shift
      ;;
    --method)
      [[ $# -ge 2 ]] || { echo "Missing value for --method" >&2; exit 2; }
      METHOD="$2"
      shift 2
      ;;
    --team-id)
      [[ $# -ge 2 ]] || { echo "Missing value for --team-id" >&2; exit 2; }
      TEAM_ID="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || { echo "Missing value for --build-number" >&2; exit 2; }
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --output-dir" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$METHOD" in
  app-store-connect|release-testing|debugging) ;;
  *)
    echo "Unsupported method: ${METHOD}" >&2
    echo "Use app-store-connect, release-testing, or debugging." >&2
    exit 2
    ;;
esac

if [[ "$DESTINATION" == "upload" && "$METHOD" != "app-store-connect" ]]; then
  echo "--upload requires --method app-store-connect." >&2
  exit 2
fi

if [[ -z "$TEAM_ID" || "$TEAM_ID" == "YOUR_TEAM_ID" ]]; then
  echo "Set APPLE_TEAM_ID or pass --team-id with your Apple Developer team ID." >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
ARCHIVE_PATH="${OUTPUT_DIR}/GrokApp-${BUILD_NUMBER}.xcarchive"
EXPORT_PATH="${OUTPUT_DIR}/export-${BUILD_NUMBER}"
EXPORT_OPTIONS="$(mktemp -t grok-build-export-options)"
trap 'rm -f "$EXPORT_OPTIONS"' EXIT

plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert method -string "$METHOD" "$EXPORT_OPTIONS"
plutil -insert destination -string "$DESTINATION" "$EXPORT_OPTIONS"
plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
plutil -insert uploadSymbols -bool YES "$EXPORT_OPTIONS"

echo "Archiving ${SCHEME} for physical iOS devices..."
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

if [[ "$DESTINATION" == "upload" ]]; then
  echo "Uploading build ${BUILD_NUMBER} to App Store Connect..."
else
  echo "Exporting build ${BUILD_NUMBER}..."
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

if [[ "$DESTINATION" == "upload" ]]; then
  echo "Upload complete. After Apple finishes processing it, enable this build for TestFlight testers."
else
  echo "Export complete: ${EXPORT_PATH}"
fi
