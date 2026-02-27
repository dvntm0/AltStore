#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METADATA_JSON="$SCRIPT_DIR/metadata.json"
PRESETS_JSON="$SCRIPT_DIR/template.json"
WORKDIR=$(mktemp -d)
APPS_FULL_JSON="$WORKDIR/apps_full.json"
APPS_MERGED_JSON="$WORKDIR/apps_merged.json"
SOURCE_UPDATE_TIME=$(TZ=Europe/Moscow date +"%Y-%m-%dT%H:%M:%S+03:00")

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "[]" > "$APPS_FULL_JSON"

jq -c 'to_entries[]' "$METADATA_JSON" | while read -r entry; do
  BUNDLE_ID=$(echo "$entry" | jq -r '.key')
  app_json=$(echo "$entry" | jq '.value')

  DISPLAY_NAME=$(echo "$app_json" | jq -r '.displayName // empty')
  IPA_URL=$(echo "$app_json" | jq -r '.ipaURL // empty')
  DOWNLOAD_URL=$(echo "$app_json" | jq -r '.ipaURL // empty')
  VERSION_DESCRIPTION=$(echo "$app_json" | jq -r '.versionDescription // empty')
  DATE=$(echo "$app_json" | jq -r '.date // empty')
  TINT_COLOR=$(echo "$app_json" | jq -r '.tintColor // empty')
  SUBTITLE=$(echo "$app_json" | jq -r '.subtitle // empty')
  DESCRIPTION=$(echo "$app_json" | jq -r '.appDescription // empty')
  ICON_URL=$(echo "$app_json" | jq -r '.iconURL // empty')
  SCREENSHOTS=$(echo "$app_json" | jq -c '.screenshots // []')

  echo "Processing $DISPLAY_NAME"

  IPA_FILE="$WORKDIR/app.ipa"

  if [[ "$IPA_URL" =~ ^https?:// ]]; then
    echo "Downloading IPA from GitHub Releases..."
    if [[ "$IPA_URL" == *"github.com"* ]]; then
      curl -H "Authorization: token $GITHUB_TOKEN" -L -o "$IPA_FILE" "$IPA_URL"
    else
      curl -L -o "$IPA_FILE" "$IPA_URL"
    fi
  else
    echo "Copying local IPA..."
    cp "$IPA_URL" "$IPA_FILE"
  fi

  TMP_DIR=$(mktemp -d)
  unzip -q "$IPA_FILE" -d "$TMP_DIR"

  APP_PATH=$(find "$TMP_DIR/Payload" -name "*.app" -type d | head -n 1)
  INFO_PLIST="$APP_PATH/Info.plist"

  EXECUTABLE=$(defaults read "$INFO_PLIST" CFBundleExecutable 2>/dev/null || echo "")
  BUNDLE_ID=$(defaults read "$INFO_PLIST" CFBundleIdentifier 2>/dev/null || echo "")
  VERSION=$(defaults read "$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || echo "")
  MIN_OS_VERSION=$(defaults read "$INFO_PLIST" MinimumOSVersion 2>/dev/null || echo "")
  ENTITLEMENTS_RAW=$(ldid -e "$APP_PATH/$EXECUTABLE" 2>/dev/null || echo '{}')
  ENTITLEMENTS_JSON=$(echo "$ENTITLEMENTS_RAW" | plutil -convert json -o - - 2>/dev/null || echo '{}')
  ENTITLEMENTS=$(echo "$ENTITLEMENTS_JSON" | jq 'keys' 2>/dev/null || echo '[]')
  PRIVACY=$(plutil -convert json -o - "$INFO_PLIST" 2>/dev/null | jq 'to_entries | map(select(.key | test("^NS.*UsageDescription$")) | .value = (if .value == "" then "No usage description provided by app'\''s developer" else .value end)) | from_entries' 2> privacy_error.log || echo '{}')
  SIZE=$(stat -f%z "$IPA_FILE" 2>/dev/null || echo 0)

  FULL_APP_JSON=$(jq -n \
    --arg displayName "$DISPLAY_NAME" \
    --arg bundleIdentifier "$BUNDLE_ID" \
    --arg version "$VERSION" \
    --arg minOSVersion "$MIN_OS_VERSION" \
    --arg date "$DATE" \
    --argjson size "$SIZE" \
    --argjson entitlements "$ENTITLEMENTS" \
    --argjson privacy "$PRIVACY" \
    --arg versionDescription "$VERSION_DESCRIPTION" \
    --arg iconURL "$ICON_URL" \
    --arg downloadURL "$DOWNLOAD_URL" \
    --arg tintColor "$TINT_COLOR" \
    --arg subtitle "$SUBTITLE" \
    --arg description "$DESCRIPTION" \
    --argjson screenshots "$SCREENSHOTS" \
    '{
      displayName: $displayName,
      bundleIdentifier: $bundleIdentifier,
      version: $version,
      minOSVersion: $minOSVersion,
      date: $date,
      size: $size,
      entitlements: $entitlements,
      privacy: $privacy,
      versionDescription: $versionDescription,
      iconURL: $iconURL,
      downloadURL: $downloadURL,
      tintColor: $tintColor,
      subtitle: $subtitle,
      description: $description,
      screenshots: $screenshots
    }' 2> full_app_json_error.log || {
      echo "Failed creating full app info for $DISPLAY_NAME"
      rm -rf "$TMP_DIR"
      continue
    })

  jq --argjson app "$FULL_APP_JSON" '. + [$app]' "$APPS_FULL_JSON" > "$APPS_FULL_JSON.tmp" 2> apps_full_json_error.log || {
    echo "Failed to add $DISPLAY_NAME in apps_full.json"
    rm -rf "$TMP_DIR"
    continue
  }
  mv "$APPS_FULL_JSON.tmp" "$APPS_FULL_JSON"

  echo "$DISPLAY_NAME has been successfully added"
  rm -rf "$TMP_DIR"
done

echo
echo "apps_full.json has been successfully generated"
echo "Merging duplicate bundle IDs for repo/sidestore..."

jq '
  group_by(.bundleIdentifier) |
  map(
    sort_by(.version | split(".") | map(tonumber)) | reverse |
    .[0] as $primary |
    (.[1:] | map({
      version: .version,
      minOSVersion: .minOSVersion,
      date: .date,
      size: .size,
      downloadURL: .downloadURL,
      versionDescription: .versionDescription
    })) as $extra |
    $primary + { extraVersions: $extra }
  )
' "$APPS_FULL_JSON" > "$APPS_MERGED_JSON"

echo "Merge complete"

ALTSTORE_JSON="$SCRIPT_DIR/../repo.json"
SIDESTORE_JSON="$SCRIPT_DIR/../sidestore.json"
ESIGN_JSON="$SCRIPT_DIR/../esign.json"
GBOX_JSON="$SCRIPT_DIR/../gbox.json"
FEATHER_JSON="$SCRIPT_DIR/../feather.json"
SCARLET_JSON="$SCRIPT_DIR/../scarlet.json"
RAW_REPO_JSON="$SCRIPT_DIR/../raw_repo.json"

echo "Generating store json files..."
generate_store_json() {
  local store_key=$1
  local output_file=$2
  local apps_key=$3
  local jq_transform=$4
  local source_file="${5:-$APPS_FULL_JSON}"

  echo "Creating $output_file..."

  preset=$(jq -r --arg key "$store_key" '.[$key]' "$PRESETS_JSON")
  if [[ -z "$preset" || "$preset" == "null" ]]; then
    echo "Error: Preset for $store_key not found in template.json"
    exit 1
  fi

  apps_array=$(jq "$jq_transform" "$source_file")

  if [[ "$store_key" == "gbox.json" ]]; then
    echo "$preset" | jq --argjson apps "$apps_array" --arg sourceUpdateTime "$SOURCE_UPDATE_TIME" \
      '. + { appRepositories: $apps, sourceUpdateTime: $sourceUpdateTime }' > "$output_file"
  elif [[ "$apps_key" == "appRepositories" ]]; then
    echo "$preset" | jq --argjson apps "$apps_array" '. + { appRepositories: $apps }' > "$output_file"
  elif [[ "$apps_key" == "Tweaked" ]]; then
    echo "$preset" | jq --argjson apps "$apps_array" '. + { Tweaked: $apps }' > "$output_file"
  else
    echo "$preset" | jq --argjson apps "$apps_array" '.apps = $apps' > "$output_file"
  fi

  echo "$output_file has been created"
}

generate_store_json "repo.json" "$ALTSTORE_JSON" "apps" 'map({
  name: .displayName,
  bundleIdentifier: .bundleIdentifier,
  developerName: "dvntm",
  subtitle: .subtitle,
  localizedDescription: .description,
  iconURL: .iconURL,
  tintColor: .tintColor,
  screenshots: .screenshots,
  appPermissions: {
    entitlements: .entitlements,
    privacy: .privacy
  },
  versions: (
    [{
      version: .version,
      minOSVersion: .minOSVersion,
      date: .date,
      size: .size,
      downloadURL: .downloadURL,
      localizedDescription: .versionDescription
    }]
    + (.extraVersions | map({
      version: .version,
      minOSVersion: .minOSVersion,
      date: .date,
      size: .size,
      downloadURL: .downloadURL,
      localizedDescription: .versionDescription
    }))
  )
})' "$APPS_MERGED_JSON"

generate_store_json "sidestore.json" "$SIDESTORE_JSON" "apps" 'map({
  name: .displayName,
  bundleIdentifier: .bundleIdentifier,
  developerName: "dvntm",
  subtitle: .subtitle,
  localizedDescription: .description,
  iconURL: .iconURL,
  tintColor: (.tintColor | sub("^#"; "")),
  screenshotURLs: .screenshots,
  versions: (
    [{
      version: .version,
      minOSVersion: .minOSVersion,
      date: .date,
      size: .size,
      downloadURL: .downloadURL,
      localizedDescription: .versionDescription
    }]
    + (.extraVersions | map({
      version: .version,
      minOSVersion: .minOSVersion,
      date: .date,
      size: .size,
      downloadURL: .downloadURL,
      localizedDescription: .versionDescription
    }))
  )
})' "$APPS_MERGED_JSON"

generate_store_json "esign.json" "$ESIGN_JSON" "apps" 'map({
  name: .displayName,
  bundleIdentifier: .bundleIdentifier,
  developerName: "dvntm",
  version: .version,
  versionDate: .date,
  versionDescription: .versionDescription,
  downloadURL: .downloadURL,
  localizedDescription: .description,
  iconURL: .iconURL,
  tintColor: (.tintColor | sub("^#"; "")),
  isLanZouCloud: 0,
  size: .size,
  type: 1
})'

generate_store_json "gbox.json" "$GBOX_JSON" "appRepositories" 'map({
  appType: "SELF_SIGN",
  appCateIndex: 0,
  appUpdateTime: .date,
  appName: .displayName,
  appVersion: .version,
  appImage: .iconURL,
  appPackage: .downloadURL,
  appDescription: .description
})'

generate_store_json "feather.json" "$FEATHER_JSON" "apps" 'map({
  name: .displayName,
  bundleIdentifier: .bundleIdentifier,
  developerName: "dvntm",
  subtitle: .subtitle,
  localizedDescription: .description,
  iconURL: .iconURL,
  tintColor: .tintColor,
  screenshotURLs: .screenshots,
  appPermissions: {
    entitlements: .entitlements,
    privacy: .privacy
  },
  versions: (
    [{
      version: .version,
      minOSVersion: .minOSVersion,
      date: .date,
      size: .size,
      downloadURL: .downloadURL,
      localizedDescription: .versionDescription
    }]
    + (.extraVersions | map({
      version: .version,
      minOSVersion: .minOSVersion,
      date: .date,
      size: .size,
      downloadURL: .downloadURL,
      localizedDescription: .versionDescription
    }))
  ),
  version: .version,
  size: .size
})' "$APPS_MERGED_JSON"

generate_store_json "raw_repo.json" "$RAW_REPO_JSON" "apps" 'map({
  name: .displayName,
  bundleIdentifier: .bundleIdentifier,
  subtitle: .subtitle,
  localizedDescription: .description,
  iconURL: .iconURL,
  tintColor: .tintColor,
  screenshotURLs: .screenshots,
  versions: [{
    version: .version,
    minOSVersion: .minOSVersion,
    date: .date,
    size: .size,
    downloadURL: .downloadURL,
    localizedDescription: .versionDescription
  }],
  version: .version,
  size: .size
})'

generate_store_json "scarlet.json" "$SCARLET_JSON" "Tweaked" 'map({
  name: .displayName,
  version: .version,
  icon: .iconURL,
  down: .downloadURL,
  category: "Tweaked Apps",
  description: .description,
  bundleID: .bundleIdentifier,
  appstore: .bundleIdentifier,
  changelog: .versionDescription
})'

rm -f "$SCRIPT_DIR"/*.error
echo "DONE!!!"