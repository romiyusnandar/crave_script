#!/bin/bash
#
# LineageOS 23.2 build script for Sony tama devices on foss.crave.io
#
# Usage:
#   crave run --no-patch -- "curl -fsSL https://raw.githubusercontent.com/romiyusnandar/crave_script/main/lineage.sh | bash -s -- --akari"
#
# Notes:
#   - Run this from inside the LineageOS 23.2 crave project workspace
#     (or pass --projectID <id> to `crave run`).
#   - Options: --akari | --apollo | --akatsuki | --aurora
#     Only akari is fully wired to romiyusnandar forks right now; fork the
#     device/vendor repos for the other codenames first.
#   - If built on AxionAOSP, its Vulkan-first defaults are overridden so the
#     device defaults to OpenGL (see force_opengl_default).

set -o pipefail

# =========================================================
# CONFIGURATION
# =========================================================
BUILD_TARGET="LineageOS"
ANDROID_VERSION="23.2"
DEVICE_CODE=""

BASE_REPO_INIT="repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --depth=1"

KERNEL_REPO="https://github.com/romiyusnandar/kernel_sony_sdm845"
KERNEL_BRANCH="bpf"

HARDWARE_SONY_REPO="https://github.com/LineageOS/android_hardware_sony_SonyOpenTelephony"
HARDWARE_SONY_BRANCH="lineage-23.2"

DEVICE_COMMON_REPO="https://github.com/romiyusnandar/device_sony_tama-common"
DEVICE_COMMON_BRANCH="lineage-23.2"

VENDOR_COMMON_REPO="https://github.com/aoitsme/proprietary_vendor_sony_tama-common"
VENDOR_COMMON_BRANCH="lineage-23.2"

# Patches to apply after sync, before build.
# Format: "target_path|patch_url"  (applied with `git am -3`)
# Uncomment the camera fix below to mirror aoitsme's axion.sh.
PATCHES=(
  # "frameworks/native|https://raw.githubusercontent.com/aoitsme/crave_script/main/patch/001-temp-fix-camera.patch"
  # "frameworks/native|https://raw.githubusercontent.com/aoitsme/crave_script/main/patch/002-temp-fix-camera.patch"
)

# Telegram notifications (base64-encoded credentials, override via env if needed)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-$(echo "ODQ2NTAyMTE4MjpBQUc0YzdjejBOMktUbTBlcUxkc05kZVJZVUR3Q01GSVF1Zw==" | base64 -d)}"
TG_CHAT_ID="${TG_CHAT_ID:-$(echo "LTEwMDE5MzAxNjgyNjk=" | base64 -d)}"

# Setup timezone
export TZ="Asia/Jakarta"

# =========================================================
# HELPERS
# =========================================================

usage() {
  echo "Usage: $0 [--akari | --apollo | --akatsuki | --aurora]"
}

tg_send() {
  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    return 0
  fi
  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" &> /dev/null
}

format_duration() {
  local T=$1
  local H=$((T/3600))
  local M=$(( (T%3600)/60 ))
  local S=$((T%60))
  printf "%02d hours, %02d minutes, %02d seconds" "$H" "$M" "$S"
}

upload_files() {
  if [ $# -eq 0 ]; then
    echo "Error: No file specified for upload." >&2
    echo "UPLOAD_FAILED"
    return 1
  fi

  echo "Fetching best server from Gofile..." >&2
  BEST_SERVER=$(curl -s https://api.gofile.io/servers | grep -oP '(?<="name":")[^"]*' | head -n 1)
  if [ -z "$BEST_SERVER" ]; then
    echo "Failed to get active server. Falling back to store3..." >&2
    BEST_SERVER="store3"
  fi

  for FILE in "$@"; do
    if [ ! -f "$FILE" ]; then
      echo "\"$FILE\" not found! Skipping." >&2
      continue
    fi

    FILENAME="${FILE##*/}"
    FILESIZE=$(du -h "$FILE" | cut -f1)

    echo "Uploading $FILENAME ($FILESIZE) via $BEST_SERVER..." >&2
    RESPONSE=$(curl -# -F "file=@$FILE" "https://${BEST_SERVER}.gofile.io/contents/uploadfile")
    UPLOAD_STATUS=$(echo "$RESPONSE" | grep -o '"status":"ok"')

    if [[ -n "$UPLOAD_STATUS" ]]; then
      GOLINK=$(echo "$RESPONSE" | grep -oP '"downloadPage":"\K[^"]+')
      echo "Success!" >&2
      echo "Link: ${GOLINK}" >&2
      echo "${FILENAME}|${FILESIZE}|${GOLINK}"
      return 0
    else
      echo "Upload failed! Response: $RESPONSE" >&2
      echo "UPLOAD_FAILED"
      return 1
    fi
  done
}

apply_patches() {
  if [ ${#PATCHES[@]} -eq 0 ]; then
    echo "No patches to apply."
    return 0
  fi

  for entry in "${PATCHES[@]}"; do
    [ -z "$entry" ] && continue
    local dir="${entry%%|*}"
    local url="${entry#*|}"
    local file="/tmp/$(basename "$url")"
    echo "Applying patch: $url -> $dir"
    wget -q "$url" -O "$file" || { echo "Download failed: $url"; return 1; }
    ( cd "$dir" && git am -3 "$file" ) || { echo "Patch failed: $url"; return 1; }
  done
  return 0
}

# AxionAOSP forces Vulkan-first; turn it back to an OpenGL default.
# No-op on non-Axion builds (dir won't exist).
force_opengl_default() {
  local prop="device/axion/common/config/defaults_common.prop"
  local vk="device/axion/common/config/vulkan/vulkan.mk"

  if [ ! -f "$prop" ]; then
    echo "Axion common prop not found, skipping OpenGL default override."
    return 0
  fi

  echo "Forcing OpenGL default (disabling Axion Vulkan-first)..."
  sed -i 's/^debug\.hwui\.renderer=.*/debug.hwui.renderer=skiagl/' "$prop"
  sed -i 's/^debug\.renderengine\.backend=.*/debug.renderengine.backend=skiaglthreaded/' "$prop"
  if [ -f "$vk" ]; then
    sed -i 's/^TARGET_USES_VULKAN := *true/TARGET_USES_VULKAN := false/' "$vk"
  fi
  return 0
}

set_device_vars() {
  case "$1" in
    akari)
      DEVICE_CODE="akari"
      DEVICE_REPO="https://github.com/romiyusnandar/device_sony_akari"
      DEVICE_BRANCH="lineage-23.2"
      VENDOR_REPO="https://github.com/romiyusnandar/vendor_sony_akari"
      VENDOR_BRANCH="lineage-23.2"
      ;;
    apollo|akatsuki|aurora)
      DEVICE_CODE="$1"
      DEVICE_REPO="https://github.com/romiyusnandar/device_sony_$1"
      DEVICE_BRANCH="lineage-23.2"
      VENDOR_REPO="https://github.com/romiyusnandar/vendor_sony_$1"
      VENDOR_BRANCH="lineage-23.2"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

# =========================================================
# BUILD
# =========================================================
start_build_process() {
  START_TIME=$(date +%s)

  echo "Sending build start message..."
  tg_send "⚙️ <b>ROM Build Started!</b>

• <b>ROM:</b> ${BUILD_TARGET}
• <b>Android:</b> ${ANDROID_VERSION}
• <b>Device:</b> ${DEVICE_CODE}
• <b>Server:</b> foss.crave.io
• <b>Start:</b> $(date '+%Y-%m-%d %H:%M:%S %Z')"

  echo "Removing local changes..."
  rm -rf .repo/local_manifests
  rm -rf device/sony/"$DEVICE_CODE" device/sony/tama-common
  rm -rf kernel/sony/sdm845
  rm -rf hardware/sony/SonyOpenTelephony
  rm -rf vendor/sony/"$DEVICE_CODE" vendor/sony/tama-common

  echo "Set github account..."
  git config --global user.name "romiyusnandar"
  git config --global user.email "yusromi04@gmail.com"

  echo "Initializing repo..."
  $BASE_REPO_INIT

  echo "Syncing sources..."
  if [ -f /opt/crave/resync.sh ]; then
    /opt/crave/resync.sh
  fi
  repo sync

  echo "Cloning device trees..."
  git clone "$KERNEL_REPO" -b "$KERNEL_BRANCH" --depth=1 kernel/sony/sdm845
  git clone "$HARDWARE_SONY_REPO" -b "$HARDWARE_SONY_BRANCH" --depth=1 hardware/sony/SonyOpenTelephony
  git clone "$DEVICE_REPO" -b "$DEVICE_BRANCH" --depth=1 device/sony/"$DEVICE_CODE"
  git clone "$DEVICE_COMMON_REPO" -b "$DEVICE_COMMON_BRANCH" --depth=1 device/sony/tama-common
  git clone "$VENDOR_REPO" -b "$VENDOR_BRANCH" --depth=1 vendor/sony/"$DEVICE_CODE"
  git clone "$VENDOR_COMMON_REPO" -b "$VENDOR_COMMON_BRANCH" --depth=1 vendor/sony/tama-common

  echo "Applying patches..."
  apply_patches || { echo "Patch step failed, aborting build."; exit 1; }

  force_opengl_default

  echo "Starting ROM build..."
  source build/envsetup.sh
  brunch "$DEVICE_CODE"
  BUILD_STATUS=$?

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  DURATION_FORMATTED=$(format_duration "$DURATION")

  if [[ $BUILD_STATUS -eq 0 ]]; then
    ZIP_FILE=$(ls -t out/target/product/"$DEVICE_CODE"/*"$DEVICE_CODE"*.zip 2>/dev/null | head -n 1)
    UPLOAD_RESULT=$(upload_files "$ZIP_FILE")

    if [[ "$UPLOAD_RESULT" != "UPLOAD_FAILED" ]]; then
      IFS='|' read -r FILENAME FILESIZE GOLINK <<< "$UPLOAD_RESULT"
      tg_send "✅ <b>ROM Build Finished!</b>

• <b>ROM:</b> ${BUILD_TARGET}
• <b>Device:</b> ${DEVICE_CODE}
• <b>File:</b> ${FILENAME}
• <b>Size:</b> ${FILESIZE}
• <b>Link:</b> ${GOLINK}
• <b>Duration:</b> ${DURATION_FORMATTED}"
    else
      tg_send "✅ <b>ROM Build Finished!</b> (upload failed)

• <b>Device:</b> ${DEVICE_CODE}
• <b>Duration:</b> ${DURATION_FORMATTED}"
    fi
  else
    tg_send "❌ <b>ROM Build Failed!</b>

• <b>Device:</b> ${DEVICE_CODE}
• <b>Exit code:</b> ${BUILD_STATUS}
• <b>Duration:</b> ${DURATION_FORMATTED}"
    exit "$BUILD_STATUS"
  fi
}

# =========================================================
# MAIN
# =========================================================
if [ -z "$1" ]; then
  usage
  exit 1
fi

set_device_vars "$1"
start_build_process
