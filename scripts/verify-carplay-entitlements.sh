#!/bin/sh

set -eu

entitlements_path="${PROJECT_DIR}/${CODE_SIGN_ENTITLEMENTS}"

require_true_entitlement() {
  key="$1"
  value=$(/usr/libexec/PlistBuddy -c "Print :${key}" "$entitlements_path" 2>/dev/null || true)

  if [ "$value" != "true" ]; then
    echo "error: Required CarPlay entitlement '${key}' is missing from ${CODE_SIGN_ENTITLEMENTS}." >&2
    exit 1
  fi
}

require_true_entitlement "com.apple.developer.carplay-audio"
require_true_entitlement "com.apple.developer.carplay-video"
