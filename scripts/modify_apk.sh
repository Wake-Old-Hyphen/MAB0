#!/usr/bin/env bash
set -euo pipefail
APK_IN="$1"
OUT_DIR="$2"
TOOLS_DIR="$3"
KEYSTORE_PATH="$4"
KEYSTORE_PASS="$5"
KEY_ALIAS="$6"
KEY_PASS="$7"

mkdir -p "$OUT_DIR"
TEMP_DIR=$(mktemp -d)
cp "$APK_IN" "$TEMP_DIR/app.apk"
cd "$TEMP_DIR"

# decode APK
java -jar "$TOOLS_DIR/apktool.jar" d -f app.apk -o decoded

MANIFEST="decoded/AndroidManifest.xml"
if [ ! -f "$MANIFEST" ]; then
  echo "Manifest not found"; exit 1
fi

# Extract package name and sdk nodes if present
PACKAGE=$(xmlstarlet sel -t -v "/manifest/@package" decoded/AndroidManifest.xml 2>/dev/null || echo "com.modified.app")
MINSDK=$(xmlstarlet sel -t -v "/manifest/uses-sdk/@android:minSdkVersion" decoded/AndroidManifest.xml 2>/dev/null || true)
TARGETSDK=$(xmlstarlet sel -t -v "/manifest/uses-sdk/@android:targetSdkVersion" decoded/AndroidManifest.xml 2>/dev/null || true)

# Build new manifest header with allowed permissions
cat > "$MANIFEST.tmp" <<MAN
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$PACKAGE">
MAN

if [ -n "$MINSDK" ] || [ -n "$TARGETSDK" ]; then
  echo -n "  <uses-sdk" >> "$MANIFEST.tmp"
  [ -n "$MINSDK" ] && echo -n " android:minSdkVersion=\"$MINSDK\"" >> "$MANIFEST.tmp"
  [ -n "$TARGETSDK" ] && echo -n " android:targetSdkVersion=\"$TARGETSDK\"" >> "$MANIFEST.tmp"
  echo " />" >> "$MANIFEST.tmp"
fi

cat >> "$MANIFEST.tmp" <<PERMS
  <uses-permission android:name="android.permission.INTERNET" />
  <uses-permission android:name="android.permission.WAKE_LOCK" />
  <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
  <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
  <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
PERMS

# Append application node from original manifest
xmlstarlet sel -t -c "/manifest/application" decoded/AndroidManifest.xml >> "$MANIFEST.tmp"
echo "</manifest>" >> "$MANIFEST.tmp"

mv "$MANIFEST.tmp" "$MANIFEST"

# rebuild
java -jar "$TOOLS_DIR/apktool.jar" b decoded -o rebuilt.apk

# align
if command -v zipalign >/dev/null 2>&1; then
  zipalign -v -p 4 rebuilt.apk aligned.apk || cp rebuilt.apk aligned.apk
else
  cp rebuilt.apk aligned.apk
fi

OUTPUT_APK="$OUT_DIR/modified-$(basename "$APK_IN")"

if [ -n "$KEYSTORE_PATH" ] && [ -f "$KEYSTORE_PATH" ]; then
  if command -v apksigner >/dev/null 2>&1; then
    apksigner sign --ks "$KEYSTORE_PATH" --ks-pass pass:"$KEYSTORE_PASS" --key-pass pass:"$KEY_PASS" --out "$OUTPUT_APK" aligned.apk --ks-key-alias "$KEY_ALIAS"
  else
    jarsigner -keystore "$KEYSTORE_PATH" -storepass "$KEYSTORE_PASS" -keypass "$KEY_PASS" aligned.apk "$KEY_ALIAS"
    cp aligned.apk "$OUTPUT_APK"
  fi
else
  cp aligned.apk "$OUTPUT_APK"
fi

echo "$OUTPUT_APK"
