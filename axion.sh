#!/bin/bash
#
# AxionAOSP 23.2 build script for Sony tama devices on foss.crave.io
#
# Usage:
#   crave run --no-patch -- "curl -fsSL https://raw.githubusercontent.com/romiyusnandar/crave_script/main/axion.sh | bash -s -- --akari"
#
# Notes:
#   - Run this from inside the Axion 23.2 crave project workspace
#     (or pass --projectID <id> to `crave run`).
#   - Options: --akari | --apollo | --akatsuki | --aurora
#   - Adapts aoitsme's axion.sh: our own device/akari, device/tama-common and
#     kernel forks, our telegram creds, camera patches enabled, and OpenGL
#     forced as the renderer default.

set -o pipefail

# =========================================================
# CONFIGURATION
# =========================================================
BUILD_TARGET="AxionAOSP"
ANDROID_VERSION="16"
DEVICE_CODE=""

BASE_REPO_INIT="repo init --depth=1 -u https://github.com/AxionAOSP/android.git -b lineage-23.2 --git-lfs"

# --- Our forks (the only repos swapped from aoitsme's script) ---
KERNEL_REPO="https://github.com/romiyusnandar/kernel_sony_sdm845"
KERNEL_BRANCH="bpf"

DEVICE_COMMON_REPO="https://github.com/romiyusnandar/device_sony_tama-common"
DEVICE_COMMON_BRANCH="lineage-23.2"

# --- Everything else kept from aoitsme's axion.sh ---
AXION_SDK_REPO="https://github.com/aoitsme/android_axion_sdk"
AXION_SDK_BRANCH="lineage-23.2"
HARDWARE_INTERFACES_REPO="https://github.com/aoitsme/axion_hardware_interfaces"
HARDWARE_INTERFACES_BRANCH="lineage-23.2"
KERNEL_CONFIGS_REPO="https://github.com/aoi-itsme/android_kernel_configs"
KERNEL_CONFIGS_BRANCH="lineage-23.2"
HARDWARE_SONY_REPO="https://github.com/aoitsme/android_hardware_sony_SonyOpenTelephony"
HARDWARE_SONY_BRANCH="lineage-23.2"
VENDOR_COMMON_REPO="https://github.com/aoitsme/proprietary_vendor_sony_tama-common"
VENDOR_COMMON_BRANCH="lineage-23.2"
KEYS_REPO="https://github.com/aoi-itsme/keys"
KEYS_BRANCH="new"

CAMERA_PATCH_BASE="https://raw.githubusercontent.com/aoitsme/crave_script/refs/heads/main/patch"

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

apply_camera_patches() {
  echo "Patching frameworks/native (camera)..."
  cd frameworks/native || return 1
  wget -q "$CAMERA_PATCH_BASE/001-temp-fix-camera.patch" -O 001-temp-fix-camera.patch || { cd - >/dev/null; return 1; }
  wget -q "$CAMERA_PATCH_BASE/002-temp-fix-camera.patch" -O 002-temp-fix-camera.patch || { cd - >/dev/null; return 1; }
  git am -3 001-temp-fix-camera.patch || { echo "001 patch failed"; git am --abort; cd - >/dev/null; return 1; }
  git am -3 002-temp-fix-camera.patch || { echo "002 patch failed"; git am --abort; cd - >/dev/null; return 1; }
  cd - >/dev/null
  return 0
}

# AxionAOSP forces Vulkan-first; turn it back to an OpenGL default.
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
      DEVICE_BRANCH="axion"
      ;;
    apollo|akatsuki|aurora)
      DEVICE_CODE="$1"
      DEVICE_REPO="https://github.com/romiyusnandar/device_sony_$1"
      DEVICE_BRANCH="axion"
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
  rm -rf axion_sdk
  rm -rf hardware/interfaces
  rm -rf frameworks/native
  rm -rf kernel/configs
  rm -rf kernel/sony
  rm -rf device/sony
  rm -rf hardware/sony
  rm -rf vendor/sony
  rm -rf vendor/lineage-priv

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

  echo "Replacing some repositories..."
  rm -rf axion_sdk hardware/interfaces kernel/configs
  git clone "$AXION_SDK_REPO" -b "$AXION_SDK_BRANCH" --depth=1 axion_sdk
  git clone "$HARDWARE_INTERFACES_REPO" -b "$HARDWARE_INTERFACES_BRANCH" --depth=1 hardware/interfaces
  git clone "$KERNEL_CONFIGS_REPO" -b "$KERNEL_CONFIGS_BRANCH" --depth=1 kernel/configs

  apply_camera_patches || { echo "Camera patch step failed, aborting."; exit 1; }

  echo "Cloning device trees..."
  git clone "$KERNEL_REPO" -b "$KERNEL_BRANCH" --depth=1 kernel/sony/sdm845
  git clone "$DEVICE_REPO" -b "$DEVICE_BRANCH" --depth=1 device/sony/"$DEVICE_CODE"
  git clone "$DEVICE_COMMON_REPO" -b "$DEVICE_COMMON_BRANCH" --depth=1 device/sony/tama-common
  git clone "$HARDWARE_SONY_REPO" -b "$HARDWARE_SONY_BRANCH" --depth=1 hardware/sony/SonyOpenTelephony
  git clone "$VENDOR_REPO" -b "$VENDOR_BRANCH" --depth=1 vendor/sony/"$DEVICE_CODE"
  git clone "$VENDOR_COMMON_REPO" -b "$VENDOR_COMMON_BRANCH" --depth=1 vendor/sony/tama-common
  git clone "$KEYS_REPO" -b "$KEYS_BRANCH" --depth=1 vendor/lineage-priv

  force_opengl_default

  echo "Starting ROM build..."
  source build/envsetup.sh
  axion "$DEVICE_CODE" userdebug va
  ax -br
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

# Vendor per-device stays on aoitsme's repos
VENDOR_REPO="https://github.com/aoitsme/proprietary_vendor_sony_${DEVICE_CODE}"
VENDOR_BRANCH="lineage-23.2"

start_build_process
