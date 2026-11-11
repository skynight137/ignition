# shellcheck shell=bash
# zsh installer. Nix supplies zsh + fzf (no root, no apt); oh-my-zsh plus
# powerlevel10k and the XDG dotfiles turn it into the interactive shell.
# ZDOTDIR is registered as a tool env var so the shell rc carries the export.

# Clone <url> into <dest>, replacing whatever is there. git refuses a non-empty
# destination and oh-my-zsh ships custom/{themes,plugins} so the child clones
# always have a parent: clone into an empty temp dir (git allows that) and move
# it into place.
_clone_into() {
  local url="$1" dest="$2" tmp
  tmp=$(mktemp -d "$XDG_CACHE_HOME/zsh-clone.XXXXXX") || die "mktemp failed"
  git clone --depth 1 --filter=blob:none "$url" "$tmp" || die "clone failed: $url"
  rm -rf -- "$dest"
  mkdir -p -- "$(dirname -- "$dest")"
  mv -- "$tmp" "$dest"
}

install_zsh() {
  step "Installing zsh"
  need_cmd nix
  need_cmd git

  # One nix profile per tool: /nix/store closures are GC'd freely, the profile
  # is the GC root and lives on the durable workspace volume, so it survives
  # the $HOME wipe. `install` is the deprecated spelling of `add`, kept because
  # it is what is validated on the box.
  # nix requires the parent of --profile to exist ("cannot read directory"
  # otherwise); create it before the install.
  mkdir -p -- "$(dirname -- "$ZSH_PROFILE")"
  nix profile install --profile "$ZSH_PROFILE" nixpkgs#zsh nixpkgs#fzf \
    || die "nix profile install failed ($ZSH_PROFILE)"

  # $XDG_BIN_HOME is the only PATH entry; link the binaries there instead of
  # letting nix append its own profile/bin line. fzf backs the zsh-fzf-history
  # search widget, so it is part of the shell, not a separate tool.
  mkdir -p -- "$XDG_BIN_HOME"
  ln -sfn "$ZSH_PROFILE/bin/zsh" "$XDG_BIN_HOME/zsh"
  ln -sfn "$ZSH_PROFILE/bin/fzf" "$XDG_BIN_HOME/fzf"
  [[ -x "$XDG_BIN_HOME/zsh" ]] || die "zsh was not linked into $XDG_BIN_HOME"

  # oh-my-zsh and its custom tree. Each clone is skipped once present so a
  # re-run only fetches what is missing.
  [[ -d "$ZSH_DIR/.git" ]] || _clone_into https://github.com/ohmyzsh/ohmyzsh "$ZSH_DIR"
  local clones=(
    "https://github.com/romkatv/powerlevel10k|$ZSH_DIR/custom/themes/powerlevel10k"
    "https://github.com/zsh-users/zsh-syntax-highlighting|$ZSH_DIR/custom/plugins/zsh-syntax-highlighting"
    "https://github.com/zsh-users/zsh-autosuggestions|$ZSH_DIR/custom/plugins/zsh-autosuggestions"
    "https://github.com/joshskidmore/zsh-fzf-history-search|$ZSH_DIR/custom/plugins/zsh-fzf-history-search"
    "https://github.com/marlonrichert/zsh-autocomplete|$ZSH_DIR/custom/plugins/zsh-autocomplete"
  )
  local entry url dest
  for entry in "${clones[@]}"; do
    url="${entry%%|*}"
    dest="${entry#*|}"
    [[ -d "$dest/.git" ]] || _clone_into "$url" "$dest"
  done

  # Dotfiles. .p10k.zsh is the theme's classic preset with the glyph mode the
  # box uses (the wizard's only non-default answer), so there is no generated
  # config to download and no $HOME copy: zsh reads it through $ZDOTDIR.
  local zdir="$ZSH_DOTDIR"
  mkdir -p -- "$zdir"
  cp -- "$ZSH_DIR/custom/themes/powerlevel10k/config/p10k-classic.zsh" "$zdir/.p10k.zsh"
  sed -i 's/POWERLEVEL9K_MODE=nerdfont-complete/POWERLEVEL9K_MODE=nerdfont-v3/' "$zdir/.p10k.zsh"

  # .zshrc carries literal paths, the same rule the rc emitter follows: nothing
  # here resolves $REPL_HOME, so the file is correct however zsh is launched.
  # `\$` escapes keep zsh's own expansions ($ZSH, $ZDOTDIR, the instant-prompt
  # `${(%):-%n}`) literal in the generated file.
  cat > "$zdir/.zshrc" <<EOF
# Replit (Nix, no root) shell setup for skynight137, a workspace-resident
# adaptation of the Termux-Setup .zshrc. Only durable paths appear here: \$HOME
# is wiped on recreate, the workspace is not. ZDOTDIR comes from the shared
# tool rc, so zsh finds this file and there is no \$HOME/.zshrc.
export ZDOTDIR="\${ZDOTDIR:-$zdir}"
export ZSH="$ZSH_DIR"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git python colored-man-pages zsh-syntax-highlighting zsh-autosuggestions zsh-fzf-history-search zsh-autocomplete)
source \$ZSH/oh-my-zsh.sh

# Shared shell rc: registries, TLS bundle, LD_LIBRARY_PATH, tool dirs and the
# hermes aliases block (which no-ops in zsh while REPLIT_MODE is empty).
[[ -r "$WORKSPACE/.config/bashrc" ]] && source "$WORKSPACE/.config/bashrc"
[[ -r "$XDG_CACHE_HOME/p10k-instant-prompt-\${(%):-%n}.zsh" ]] && source "$XDG_CACHE_HOME/p10k-instant-prompt-\${(%):-%n}.zsh"
[[ -f "\$ZDOTDIR/.p10k.zsh" ]] && source "\$ZDOTDIR/.p10k.zsh"
export LANG="en_US.UTF-8"
export UV_LINK_MODE=copy
alias q="exit"
alias c="clear"
alias unzsh="bash \$ZSH/tools/uninstall.sh"
# AU/AI/AR (apt update/install/remove) dropped: Replit is a Nix box, no apt.
alias penv="python3 -m venv $WORKSPACE/.venv"
alias psource="source $WORKSPACE/.venv/bin/activate"
alias pipi="$WORKSPACE/.venv/bin/pip"
alias gclone="git clone --depth 1 --filter=blob:none"
EOF

  ok "zsh installed: $XDG_BIN_HOME/zsh, dotfiles in $zdir"
  # ZDOTDIR (set in common.sh) is what lets a bare `zsh` find $zdir; the fzf
  # binary reaches PATH through $XDG_BIN_HOME.
  record_tool_env_vars ZDOTDIR
  record_tool_path_dirs "$XDG_BIN_HOME"
}
