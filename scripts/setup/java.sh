# shellcheck shell=bash
# Java toolchain (Eclipse Temurin JDK) installer. Sourced by setup.sh
# BEFORE android.sh.
#
# install_java used to live inside android.sh — Java was only needed
# for the Android SDK then. It is a standalone lane now, the same way
# Node outgrew its first consumer: other tools need a JDK too (e.g.
# REA's Ghidra provider), and a box that only needs Java should not
# have to install the whole Android SDK to get one. --java installs
# Java alone; --android-tools still pulls it in as a prerequisite
# (install_android_tools calls install_java as before).
#
# $JAVA_HOME (common.sh) is a single-major home: installing a JDK
# replaces whatever major sits there. The fleet default major is the
# profile's JAVA_MAJOR (24); a box that needs another major sets
# JAVA_MAJOR in its environment (the profile honors a pre-set value).
# ── Java toolchain ────────────────────────────────────────────────────

install_java() {
  need_cmd wget
  need_cmd tar
  local TMP_TGZ="${XDG_DATA_HOME:-$HOME/.local/share}/_jdk$JAVA_MAJOR.tar.gz"
  local TMP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/_jdk$JAVA_MAJOR-extract"

  echo "  Downloading Eclipse Temurin JDK $JAVA_MAJOR (latest GA)..."
  wget -q --show-progress -L \
    --header="Accept: application/octet-stream" \
    "https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    -O "$TMP_TGZ" || die "JDK download failed"

  echo "  Extracting Java..."
  rm -rf "$TMP_DIR" "$JAVA_HOME"
  mkdir -p "$TMP_DIR"
  tar -xzf "$TMP_TGZ" -C "$TMP_DIR"

  local EXTRACTED
  EXTRACTED=$(ls "$TMP_DIR")
  [[ -n "$EXTRACTED" ]] || die "JDK extraction produced an empty directory"
  mkdir -p "$JAVA_HOME"
  cp -a "$TMP_DIR/$EXTRACTED"/. "$JAVA_HOME/"
  rm -rf "$TMP_DIR" "$TMP_TGZ"

  symlink_bins "$JAVA_HOME/bin" java javac jar jshell javap
  ok "Java installed: $JAVA_HOME  ($("$JAVA_HOME/bin/java" --version 2>&1 | grep -v '^Picked up' | head -1))"
}

# java_major_of <java-binary> — print the major version ("25" for
# 25.0.5, "21" for 21.0.13, "8" for 1.8.0_402); empty when the binary
# is missing or its version line is unparseable.
java_major_of() {
  local bin="$1" ver maj
  [[ -x "$bin" ]] || return 0
  ver=$("$bin" --version 2>&1 | grep -v '^Picked up' | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
  [[ -n "$ver" ]] || return 0
  maj="${ver%%.*}"
  if [[ "$maj" == "1" ]]; then maj="$(printf '%s' "$ver" | cut -d. -f2)"; fi
  printf '%s' "$maj"
}

# ensure_java — consumer entry (mirrors camofox_ensure_node): guarantee
# a JDK of $JAVA_MAJOR at $JAVA_HOME, installing only when the present
# one is missing or a different major. Returns non-zero (via die in
# install_java) when the JDK cannot be obtained.
ensure_java() {
  if [[ "$(java_major_of "$JAVA_HOME/bin/java")" == "$JAVA_MAJOR" ]]; then
    return 0
  fi
  install_java
}

install_java_tools() {
  step "Java toolchain preflight"
  need_cmd wget
  need_cmd tar

  step "Creating persistent toolchain directories"
  mkdir -p "$JAVA_HOME" "$XDG_BIN_HOME" "${XDG_DATA_HOME:-$HOME/.local/share}"
  ok "Created: $JAVA_HOME"

  step "Java (Eclipse Temurin JDK $JAVA_MAJOR)"
  install_java

  step "Verification"
  if command -v java &>/dev/null; then
    ok "Java $JAVA_MAJOR: $(java --version 2>&1 | grep -v '^Picked up' | head -1)"
  else
    warn "Java $JAVA_MAJOR verification failed"
  fi

  record_tool_env_vars JAVA_HOME
  record_tool_path_dirs "$JAVA_HOME/bin" "$XDG_BIN_HOME"
  wire_tool java JAVA_HOME -- "$JAVA_HOME/bin" "$XDG_BIN_HOME"
}
