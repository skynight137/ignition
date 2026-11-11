# shellcheck shell=bash
# Android toolchain (SDK) installer. Sourced by setup.sh.
# Java itself lives in java.sh (sourced before this file): what used
# to be one lane is two now — install_java below is java.sh's, called
# as this lane's prerequisite.
# ── Android toolchain ─────────────────────────────────────────────────────────
accept_licenses() {
  mkdir -p "$SDK/licenses"
  printf "\n8933bad161af4178b1185d1a37fbf41ea5269c55\n"   > "$SDK/licenses/android-sdk-license"
  printf "\n84831b9409646a918e30573bab4c9c91346d8abd\n"  >> "$SDK/licenses/android-sdk-license"
  printf "\nd56f5187479451eabf01fb78af6dfcb131a6481e\n"  >> "$SDK/licenses/android-sdk-license"
  printf "\n33b6a2b64607f11b759f320ef9dff4ae5c47d97a\n"   > "$SDK/licenses/google-gdk-license"
  printf "\nd56f5187479451eabf01fb78af6dfcb131a6481e\n"   > "$SDK/licenses/android-googletv-license"
  printf "\n601085b94cd77f0b54ff86406957099ebe79c4d7\n"   > "$SDK/licenses/android-sdk-preview-license"
  ok "SDK license files written"

  echo "  Running sdkmanager --licenses (auto-accepting all)..."
  local log_file
  local pipeline_status
  log_file="$(mktemp)"
  set +e
  yes | ANDROID_HOME="$SDK" \
        JAVA_HOME="$JAVA_HOME" \
        JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTS_VALUE" \
        "$SDK/cmdline-tools/bin/sdkmanager" \
          --sdk_root="$SDK" --licenses >"$log_file" 2>&1
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  if (( pipeline_status[1] != 0 )); then
    cat "$log_file" >&2
    rm -f "$log_file"
    die "sdkmanager license acceptance failed"
  fi
  grep -v "^$" "$log_file" | grep -v "^-" | grep -v "^Terms" | tail -5 || true
  rm -f "$log_file"
  ok "Licenses accepted"
}

install_cmdline_tools() {
  need_cmd wget
  need_cmd unzip
  local TMP_ZIP="${XDG_DATA_HOME:-$HOME/.local/share}/_cmdline-tools.zip"
  local TMP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/_cmdline-tools-extract"
  echo "  Downloading cmdline-tools..."
  wget -q --show-progress -O "$TMP_ZIP" "$CMDLINE_TOOLS_URL" \
    || die "cmdline-tools download failed"
  echo "  Extracting cmdline-tools..."
  mkdir -p "$TMP_DIR"
  unzip -q -o "$TMP_ZIP" -d "$TMP_DIR"
  rm -rf "$SDK/cmdline-tools"
  mv "$TMP_DIR/cmdline-tools" "$SDK/cmdline-tools"
  rm -rf "$TMP_DIR" "$TMP_ZIP"
  chmod +x "$SDK/cmdline-tools/bin/sdkmanager"
  ok "cmdline-tools installed: $SDK/cmdline-tools"
}

install_sdk_pkg() {
  local pkg="$1"
  local label="$2"

  echo "  Installing $label..."
  local log_file
  log_file="$(mktemp)"
  if ! ANDROID_HOME="$SDK" \
       JAVA_HOME="$JAVA_HOME" \
       JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTS_VALUE" \
       "$SDK/cmdline-tools/bin/sdkmanager" \
         --sdk_root="$SDK" "$pkg" >"$log_file" 2>&1; then
    cat "$log_file" >&2
    rm -f "$log_file"
    die "Android SDK package installation failed: $pkg"
  fi
  grep -Ev "^$|^\[=|Preparing|Unzipping|Warning: File|^Done" "$log_file" |
    tail -5 || true
  rm -f "$log_file"
  ok "$label installed"
}

install_android_tools() {
  step "Android toolchain preflight"
  need_cmd wget
  need_cmd unzip
  need_cmd tar
  need_cmd curl
  local AVAIL_GB
  AVAIL_GB=$(df --output=avail -BG "$WORKSPACE" | tail -1 | tr -d 'G' | xargs)
  echo "  Workspace disk: ${AVAIL_GB} GB available (need ~5 GB)"
  [[ "$AVAIL_GB" -ge 5 ]] || die "Need at least 5 GB free in $WORKSPACE. Currently ${AVAIL_GB} GB."

  step "Creating persistent toolchain directories"
  mkdir -p "$SDK" "$JAVA_HOME" "$XDG_BIN_HOME" "${XDG_DATA_HOME:-$HOME/.local/share}"
  ok "Created: ${XDG_DATA_HOME:-$HOME/.local/share}/{android-sdk, java}"

  step "Android cmdline-tools and Java prerequisites"
  install_cmdline_tools &
  local cmdline_tools_pid=$!
  install_java &
  local java_pid=$!
  wait_for_jobs "Android prerequisite installation" "$cmdline_tools_pid" "$java_pid"

  step "SDK licenses"
  accept_licenses

  step "Android SDK packages"
  install_sdk_pkg "platform-tools" "platform-tools"
  install_sdk_pkg "platforms;$ANDROID_PLATFORM" "Android platform $ANDROID_PLATFORM"
  install_sdk_pkg "build-tools;$ANDROID_BUILD_TOOLS" "Android build tools $ANDROID_BUILD_TOOLS"

  symlink_bins "$SDK/cmdline-tools/bin" sdkmanager avdmanager
  symlink_bins "$SDK/platform-tools" adb
  ok "Android bin dirs registered"

  step "Writing local.properties"
  cat > "$WORKSPACE/local.properties" <<EOF
sdk.dir=$SDK
EOF
  ok "local.properties written: $WORKSPACE/local.properties"

  step "Verification"
  if command -v java &>/dev/null; then
    ok "Java $JAVA_MAJOR: $(java --version 2>&1 | grep -v '^Picked up' | head -1)"
  else
    warn "Java $JAVA_MAJOR verification failed"
  fi
  if [[ -x "$SDK/platform-tools/adb" ]]; then
    ok "adb: $("$SDK/platform-tools/adb" --version 2>&1 | head -1)"
  else
    warn "Android SDK adb not found"
  fi

  record_tool_env_vars JAVA_HOME ANDROID_HOME JAVA_TOOL_OPTIONS
  record_tool_path_dirs "$JAVA_HOME/bin" "$SDK/cmdline-tools/bin" "$SDK/platform-tools" "$XDG_BIN_HOME"
  wire_tool android JAVA_HOME ANDROID_HOME JAVA_TOOL_OPTIONS -- "$JAVA_HOME/bin" "$SDK/cmdline-tools/bin" "$SDK/platform-tools" "$XDG_BIN_HOME"
}
