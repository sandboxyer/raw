#!/bin/sh

# =============================================================================
# RAWJS & BASM INSTALLATION SCRIPT (with modular build system)
# Fully ash-compatible version
# =============================================================================

# PROJECT INFO
RAWJS_NAME="rawjs-runtime"
RAWJS_DESCRIPTION="RawJS JavaScript Runtime Environment"
BASM_NAME="basm-tool"
BASM_DESCRIPTION="Universal Assembly/Bash/Binary Runner with fallback logic"

# INSTALLATION PATHS
INSTALL_DIR="/usr/local/etc/rawjs-runtime"
BIN_DIR="/usr/local/bin"

# SOURCE PATHS
REPO_DIR=$(pwd)
RAWJS_SOURCE_DIR="$REPO_DIR"          # Main level for Raw.sh
BASM_SOURCE_DIR="$REPO_DIR/._/basm"   # BASM in ._/basm

# LOGGING
LOG_FILE="/var/log/rawjs-install.log"
LOG_MODE=false
BACKUP_DIR="/usr/local/etc/rawjs-runtime_old_$(date +%s)"

# Include .git directory (default: false)
INCLUDE_GIT=false

# =============================================================================
# BUILD SYSTEM VARIABLES (modular addition)
# =============================================================================
BUILD_MODE=false
BUILD_TAR=false
BUILD_CONFIG=false
BUILD_MESSAGE_MODE=false
BUILD_STAGED=false
BUILD_VERSION=""
BUILD_SAVE_NAME=""
BUILD_DIR="$REPO_DIR/build"
BUILD_SAVE_FILE="$REPO_DIR/buildsaves.cfg"
BUILD_SELECTED_COMMIT=""
BUILD_SELECTED_COMMIT_MSG=""
BUILD_INCLUDE_LIST="/tmp/build_include_$$.txt"
BUILD_INCLUDE_LIST_NAME="build_include_$$.txt"
SAVED_INCLUDE_LIST=""
EXCLUDE_LIST=""
EXCLUDE_DIRS_LIST=""
BUILD_FILES_LIST=""
BUILD_DIRS_LIST=""
# =============================================================================

# =============================================================================
# FUNCTION DEFINITIONS
# =============================================================================

# -----------------------------------------------------------------------------
# SYSTEM DETECTION
# -----------------------------------------------------------------------------
detect_system() {
  if [ -f /etc/alpine-release ]; then
    echo "alpine"
  elif [ -f /etc/lsb-release ] && grep -qi "ubuntu" /etc/lsb-release 2>/dev/null; then
    echo "ubuntu"
  elif [ -f /etc/os-release ] && grep -qi "alpine" /etc/os-release 2>/dev/null; then
    echo "alpine"
  elif [ -f /etc/os-release ] && grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    echo "ubuntu"
  else
    echo "unknown"
  fi
}

# -----------------------------------------------------------------------------
# ALPINE-SPECIFIC NASM BINARY REPLACEMENT
# -----------------------------------------------------------------------------
handle_alpine_nasm_replacement() {
  local system_type="$1"

  [ "$system_type" != "alpine" ] && return 0

  log_message "Alpine Linux detected - checking for Alpine-specific NASM binary..."

  local alpine_pack_nasm="$REPO_DIR/._/basm/alpine-pack/nasm-x86_64-linux"
  local target_nasm_dir="$REPO_DIR/._/basm/x86_64-linux"
  local target_nasm="$target_nasm_dir/nasm-x86_64-linux"

  if [ ! -f "$alpine_pack_nasm" ]; then
    log_message "No Alpine-specific NASM binary found in alpine-pack (already processed or not present)"
    return 0
  fi

  log_message "Found Alpine-specific NASM binary in alpine-pack"

  mkdir -p "$target_nasm_dir"

  # Remove any existing NASM binaries in target directory
  find "$target_nasm_dir" -maxdepth 1 -name "nasm*" -type f -exec rm -f {} \; 2>/dev/null

  mv "$alpine_pack_nasm" "$target_nasm"
  if [ $? -eq 0 ]; then
    log_message "✓ Moved Alpine-specific NASM binary to: $target_nasm"
    chmod +x "$target_nasm"
  else
    log_message "⚠ Warning: Failed to move Alpine-specific NASM binary"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# COMMAND CHECK
# -----------------------------------------------------------------------------
check_command() {
  command -v "$1" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log_message() {
  local message="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  if [ "$LOG_MODE" = true ]; then
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
  else
    echo "[$timestamp] $message"
  fi
}

# -----------------------------------------------------------------------------
# PROGRESS DISPLAY (ash compatible)
# -----------------------------------------------------------------------------
show_progress() {
  local message="$1"
  local pid="$2"
  echo "$message (please wait...)"
  wait $pid 2>/dev/null
  echo "$message completed."
}

# -----------------------------------------------------------------------------
# INSTALLATION FUNCTIONS
# -----------------------------------------------------------------------------
install_debs() {
  local deb_dir="$BASM_SOURCE_DIR/ubuntu-pack"
  if [ -d "$deb_dir" ]; then
    local deb_files=$(find "$deb_dir" -maxdepth 1 -name "*.deb" 2>/dev/null | tr '\n' ' ')
    if [ -n "$deb_files" ]; then
      log_message "Installing .deb packages from $deb_dir..."
      if [ "$LOG_MODE" = true ]; then
        sudo dpkg -i $deb_files &
      else
        sudo dpkg -i $deb_files > /dev/null 2>&1 &
      fi
      show_progress "Installing dependencies" $!

      log_message "Configuring packages..."
      if [ "$LOG_MODE" = true ]; then
        sudo dpkg --configure -a &
      else
        sudo dpkg --configure -a > /dev/null 2>&1 &
      fi
      show_progress "Configuring packages" $!
    else
      log_message "No .deb files found in $deb_dir. Skipping."
    fi
  else
    log_message "Deb directory ($deb_dir) does not exist. Skipping."
  fi
}

install_apks() {
  local apk_dir="$BASM_SOURCE_DIR/alpine-pack"
  [ ! -d "$apk_dir" ] && log_message "APK directory ($apk_dir) missing." && return 1
  ! check_command apk && log_message "apk not found." && return 1

  local apk_files=$(find "$apk_dir" -maxdepth 1 -name "*.apk" 2>/dev/null)
  [ -z "$apk_files" ] && log_message "No .apk files found." && return 0

  log_message "Found APK packages, installing..."

  # Bulk install attempt
  local all_apks=""
  for apk_file in $apk_files; do all_apks="$all_apks $apk_file"; done
  log_message "Attempting bulk installation..."
  if [ "$LOG_MODE" = true ]; then
    apk add --allow-untrusted $all_apks 2>&1
    local result=$?
  else
    apk add --allow-untrusted $all_apks > /dev/null 2>&1
    local result=$?
  fi

  if [ $result -eq 0 ]; then
    log_message "✓ All packages installed successfully"
  else
    log_message "Bulk install had issues, trying individual..."
    local failed=false
    for apk_file in $apk_files; do
      local pkg_name=$(basename "$apk_file")
      log_message "Installing: $pkg_name"
      if [ "$LOG_MODE" = true ]; then
        apk add --allow-untrusted "$apk_file" 2>&1 && log_message "✓ Installed" || { log_message "✗ Failed"; failed=true; }
      else
        apk add --allow-untrusted "$apk_file" > /dev/null 2>&1 && log_message "✓ Installed" || { log_message "✗ Failed"; failed=true; }
      fi
    done

    if [ "$failed" = true ]; then
      log_message "Retrying failed packages..."
      for apk_file in $apk_files; do
        local pkg_name=$(basename "$apk_file")
        local pkg_base=$(echo "$pkg_name" | sed 's/-[0-9].*//')
        if apk info -e "$pkg_base" > /dev/null 2>&1; then
          log_message "Package $pkg_base already installed, skipping"
          continue
        fi
        log_message "Second attempt: $pkg_name"
        if [ "$LOG_MODE" = true ]; then
          apk add --allow-untrusted --force "$apk_file" 2>&1 && log_message "✓ Installed (2nd)" || log_message "✗ Still failed"
        else
          apk add --allow-untrusted --force "$apk_file" > /dev/null 2>&1 && log_message "✓ Installed (2nd)" || log_message "✗ Still failed"
        fi
      done
    fi
  fi

  apk update > /dev/null 2>&1
  log_message "APK installation finished"
  return 0
}

install_alpine_packages() {
  log_message "Installing required Alpine packages..."
  install_apks

  if ! check_command ld; then
    log_message "Installing binutils from repository..."
    apk add --no-cache binutils 2>&1 || echo "Warning: Failed to install binutils"
  fi
  if ! check_command bash; then
    log_message "Installing bash from repository..."
    apk add --no-cache bash 2>&1 || echo "Warning: Failed to install bash"
  fi
}

install_ubuntu_packages() {
  local need_ld=false
  if ! check_command ld; then need_ld=true; fi
  [ "$need_ld" = false ] && log_message "All required Ubuntu packages present" && return 0

  log_message "Installing required Ubuntu packages..."
  install_debs

  if [ "$need_ld" = true ] && ! check_command ld; then
    if check_command apt-get; then
      log_message "Installing binutils from repo..."
      apt-get update -qq 2>&1
      apt-get install -y binutils 2>&1 || echo "Warning: Failed"
    fi
  fi
}

install_system_packages() {
  local system_type="$1"
  log_message "Detected system: $system_type"
  case "$system_type" in
    alpine) install_alpine_packages ;;
    ubuntu) install_ubuntu_packages ;;
    *)
      log_message "Unknown system, skipping auto package installation."
      if ! check_command ld; then
        echo "Warning: 'ld' not found. BASM .asm compilation may not work." >&2
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Preserve config files before removal
# -----------------------------------------------------------------------------
preserve_config_files() {
  PRESERVED_CONFIGS=""
  
  # Check for RawJS config.txt
  if [ -f "$INSTALL_DIR/config.txt" ]; then
    PRESERVED_CONFIGS=$(cat "$INSTALL_DIR/config.txt")
    log_message "Preserving config.txt from existing installation"
  fi
}

# -----------------------------------------------------------------------------
# Restore config files after installation
# -----------------------------------------------------------------------------
restore_config_files() {
  if [ -n "$PRESERVED_CONFIGS" ]; then
    # Create the installation directory if it doesn't exist
    mkdir -p "$INSTALL_DIR"
    
    # Restore config.txt
    echo "$PRESERVED_CONFIGS" > "$INSTALL_DIR/config.txt"
    log_message "Restored config.txt to installation directory"
  fi
}

# -----------------------------------------------------------------------------
# FILE COPYING - Using tar with explicit exclusions (most reliable)
# -----------------------------------------------------------------------------
copy_files() {
  local src_dir="$1"
  local dest_dir="$2"
  local description="$3"

  mkdir -p "$dest_dir"
  log_message "Copying $description files to $dest_dir..."

  # Build tar exclusion arguments
  local tar_excludes="--exclude='./.git'"
  tar_excludes="$tar_excludes --exclude='./.base_pool'"
  tar_excludes="$tar_excludes --exclude='./.router_locks'"
  tar_excludes="$tar_excludes --exclude='./.terminals'"
  tar_excludes="$tar_excludes --exclude='./.runtime_locks'"
  tar_excludes="$tar_excludes --exclude='./dev'"
  tar_excludes="$tar_excludes --exclude='./dev_*'"
  tar_excludes="$tar_excludes --exclude='./build_output.asm'"
  tar_excludes="$tar_excludes --exclude='./.rawjs_private'"
  tar_excludes="$tar_excludes --exclude='./output.js'"
  tar_excludes="$tar_excludes --exclude='./arch_output'"

  # If INCLUDE_GIT is true, don't exclude .git
  if [ "$INCLUDE_GIT" = true ]; then
    tar_excludes=$(echo "$tar_excludes" | sed "s|--exclude='./.git'||")
  fi

  # Use tar to copy while excluding directories
  if [ "$LOG_MODE" = true ]; then
    (cd "$src_dir" && eval "tar $tar_excludes -cf - .") | (cd "$dest_dir" && tar -xvf - 2>&1 | tee -a "$LOG_FILE") &
    copy_pid=$!
  else
    (cd "$src_dir" && eval "tar $tar_excludes -cf - .") | (cd "$dest_dir" && tar -xf - 2>/dev/null) &
    copy_pid=$!
  fi
  show_progress "Copying $description files" $copy_pid

  local dest_count=$(find "$dest_dir" -type f | wc -l)
  log_message "Copied $dest_count files"
  [ "$dest_count" -eq 0 ] && log_message "ERROR: No files copied!" && return 1
  
  # Ensure excluded directories are NOT present
  if [ -d "$dest_dir/.base_pool" ]; then
    log_message "WARNING: .base_pool was copied, removing..."
    rm -rf "$dest_dir/.base_pool"
  fi
  if [ -d "$dest_dir/.router_locks" ]; then
    log_message "WARNING: .router_locks was copied, removing..."
    rm -rf "$dest_dir/.router_locks"
  fi
  if [ -d "$dest_dir/.terminals" ]; then
    log_message "WARNING: .terminals was copied, removing..."
    rm -rf "$dest_dir/.terminals"
  fi
  if [ -d "$dest_dir/.runtime_locks" ]; then
    log_message "WARNING: .runtime_locks was copied, removing..."
    rm -rf "$dest_dir/.runtime_locks"
  fi
  
  return 0
}

# -----------------------------------------------------------------------------
# WRAPPER CREATION
# -----------------------------------------------------------------------------
create_raw_wrapper() {
  local install_dir="$1"
  local wrapper_path="$install_dir/wrappers/raw"
  log_message "Creating RawJS wrapper..."
  mkdir -p "$(dirname "$wrapper_path")"

  cat > "$wrapper_path" << 'WRAPPER_EOF'
#!/bin/sh
CALLER_DIR="$(pwd)"
INSTALL_DIR="/usr/local/etc/rawjs-runtime"
args=""
skip_next=false
for arg in "$@"; do
  if [ "$skip_next" = true ]; then
    args="$args \"$arg\""
    skip_next=false
    continue
  fi
  case "$arg" in
    --tool|--test|--reset|--log)
      args="$args \"$arg\""
      [ "$arg" = "--tool" ] && skip_next=true
      ;;
    -*)
      args="$args \"$arg\""
      ;;
    *)
      if [ -f "$CALLER_DIR/$arg" ]; then
        args="$args \"$CALLER_DIR/$arg\""
      else
        args="$args \"$arg\""
      fi
      ;;
  esac
done
cd "$CALLER_DIR" || { echo "Cannot navigate to $CALLER_DIR" >&2; exit 1; }
eval "exec bash \"$INSTALL_DIR/Raw.sh\" $args"
WRAPPER_EOF

  chmod +x "$wrapper_path"
  local dest_path="$BIN_DIR/raw"
  [ -L "$dest_path" ] && rm -f "$dest_path"
  ln -sf "$wrapper_path" "$dest_path"
  log_message "Created 'raw' command symlink"
}

create_basm_wrapper() {
  local install_dir="$1"
  local wrapper_path="$install_dir/wrappers/basm"
  log_message "Creating BASM wrapper..."
  mkdir -p "$(dirname "$wrapper_path")"

  cat > "$wrapper_path" << 'WRAPPER_EOF'
#!/bin/sh
CALLER_DIR="$(pwd)"
INSTALL_DIR="/usr/local/etc/rawjs-runtime"
cd "$CALLER_DIR" || { echo "Cannot navigate to $CALLER_DIR" >&2; exit 1; }
exec bash "$INSTALL_DIR/._basm/basm.sh" "$@"
WRAPPER_EOF

  chmod +x "$wrapper_path"
  local dest_path="$BIN_DIR/basm"
  [ -L "$dest_path" ] && rm -f "$dest_path"
  ln -sf "$wrapper_path" "$dest_path"
  log_message "Created 'basm' command symlink"
}

# -----------------------------------------------------------------------------
# VERIFICATION
# -----------------------------------------------------------------------------
verify_rawjs_structure() {
  local install_dir="$1"
  log_message "Verifying RawJS installation structure..."
  [ -f "$install_dir/Raw.sh" ] || { echo "✗ Missing Raw.sh"; return 1; }
  chmod +x "$install_dir/Raw.sh" 2>/dev/null || true
  echo "✓ Raw.sh found"
  [ -f "$install_dir/output.js" ] && echo "✓ output.js found" || echo "  Note: output.js not found"
  [ -f "$install_dir/test.js" ] && echo "✓ test.js found" || echo "  Note: test.js not found"
  
  # Verify that excluded directories are NOT present
  [ -d "$install_dir/.base_pool" ] && echo "⚠ Warning: .base_pool directory found (should be excluded)" || echo "✓ .base_pool correctly excluded"
  [ -d "$install_dir/.router_locks" ] && echo "⚠ Warning: .router_locks directory found (should be excluded)" || echo "✓ .router_locks correctly excluded"
  [ -d "$install_dir/.terminals" ] && echo "⚠ Warning: .terminals directory found (should be excluded)" || echo "✓ .terminals correctly excluded"
  [ -d "$install_dir/.runtime_locks" ] && echo "⚠ Warning: .runtime_locks directory found (should be excluded)" || echo "✓ .runtime_locks correctly excluded"
  
  return 0
}

verify_basm_structure() {
  local install_dir="$1"
  log_message "Verifying BASM installation structure..."
  [ -f "$install_dir/._basm/basm.sh" ] || { echo "✗ Missing basm.sh"; return 1; }
  chmod +x "$install_dir/._basm/basm.sh" 2>/dev/null || true
  echo "✓ basm.sh found"

  local has_any_arch=false
  for arch in arm-linux i386-linux x86_64-linux; do
    if [ -d "$install_dir/._basm/$arch" ]; then
      echo "✓ Found architecture: $arch"
      has_any_arch=true
      find "$install_dir/._basm/$arch" -maxdepth 1 -name "nasm*" -type f -exec chmod +x {} \; 2>/dev/null
    fi
  done
  [ "$has_any_arch" = false ] && echo "⚠ No NASM architecture directories found"

  if check_command ld; then
    echo "✓ System linker (ld) found"
  else
    echo "⚠ System linker (ld) not found"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# REMOVAL AND CLEANUP
# -----------------------------------------------------------------------------
remove_installation() {
  log_message "Removing existing installation..."
  
  # Preserve config files before removal
  preserve_config_files
  
  [ -L "$BIN_DIR/raw" ] && rm -f "$BIN_DIR/raw" && log_message "Removed symlink: raw"
  [ -L "$BIN_DIR/basm" ] && rm -f "$BIN_DIR/basm" && log_message "Removed symlink: basm"
  [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR" && log_message "Removed installation directory"
}

cleanup() {
  [ -d "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR" 2>/dev/null || true
}

interrupt_handler() {
  log_message "Installation interrupted. Cleaning up..."
  cleanup
  exit 1
}

# =============================================================================
# BUILD SYSTEM (MODULAR ADDITION - ash compatible)
# =============================================================================

# -----------------------------------------------------------------------------
# UTILITY FUNCTIONS
# -----------------------------------------------------------------------------
sanitize_filename() {
  local input="$1"
  local sanitized=$(echo "$input" | tr ' ' '_' | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//' | sed 's/_$//')
  [ -z "$sanitized" ] && sanitized="build"
  echo "$sanitized"
}

get_commit_filename() {
  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    local commit_msg=$(git log -1 --pretty=%B 2>/dev/null | head -n1)
    if [ -n "$commit_msg" ]; then
      sanitize_filename "$commit_msg"
    else
      echo "initial_build"
    fi
  else
    echo "build_$(date +%Y%m%d_%H%M%S)"
  fi
}

calculate_build_version() {
  local target_commit="$1"
  [ -z "$target_commit" ] && target_commit="HEAD"

  local latest_version=""
  local latest_distance=999999999
  local temp_candidates="/tmp/build_version_candidates_$$.txt"
  : > "$temp_candidates"

  local version_tags=$(git tag --sort=-creatordate 2>/dev/null | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$')
  if [ -n "$version_tags" ]; then
    for tag in $version_tags; do
      if git merge-base --is-ancestor "$tag" "$target_commit" 2>/dev/null; then
        local distance=$(git rev-list --count "$tag..$target_commit" 2>/dev/null || echo 0)
        if [ "$distance" -lt "$latest_distance" ]; then
          latest_version="$tag"
          latest_distance="$distance"
        fi
      fi
    done
  fi

  git log --all --oneline --grep='^[0-9]\+\.[0-9]\+\(\.[0-9]\+\)\?$' --format="%H %s" 2>/dev/null | while IFS=' ' read -r hash msg; do
    if git merge-base --is-ancestor "$hash" "$target_commit" 2>/dev/null; then
      local distance=$(git rev-list --count "$hash..$target_commit" 2>/dev/null || echo 0)
      echo "${distance}|${msg}" >> "$temp_candidates"
    fi
  done

  if [ -s "$temp_candidates" ]; then
    local best=$(sort -t'|' -k1 -n "$temp_candidates" | head -1)
    local cand_dist=$(echo "$best" | cut -d'|' -f1)
    local cand_ver=$(echo "$best" | cut -d'|' -f2)
    if [ "$cand_dist" -lt "$latest_distance" ]; then
      latest_version="$cand_ver"
      latest_distance="$cand_dist"
    fi
  fi
  rm -f "$temp_candidates"

  if [ -n "$latest_version" ]; then
    if [ "$latest_distance" -gt 0 ]; then
      echo "${latest_version}.${latest_distance}"
    else
      echo "${latest_version}"
    fi
  else
    echo ""
  fi
}

format_file_size() {
  local bytes=$1
  case "$bytes" in
    ''|*[!0-9]*) echo "0B" ; return ;;
  esac
  if [ "$bytes" -ge 1073741824 ]; then
    echo "$(echo "scale=1; $bytes / 1073741824" | bc 2>/dev/null || echo $((bytes / 1073741824)))GB"
  elif [ "$bytes" -ge 1048576 ]; then
    echo "$(echo "scale=1; $bytes / 1048576" | bc 2>/dev/null || echo $((bytes / 1048576)))MB"
  elif [ "$bytes" -ge 1024 ]; then
    echo "$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo $((bytes / 1024)))KB"
  else
    echo "${bytes}B"
  fi
}

is_file_in_excluded_dir() {
  local file_to_check="$1"
  if [ -s "$EXCLUDE_DIRS_LIST" ]; then
    while IFS= read -r excluded_dir; do
      [ -z "$excluded_dir" ] && continue
      case "$file_to_check" in
        ${excluded_dir}/*|${excluded_dir}) return 0 ;;
      esac
    done < "$EXCLUDE_DIRS_LIST"
  fi
  return 1
}

calculate_build_stats() {
  local total_size=0
  local total_files=0
  while IFS='|' read -r size name; do
    [ -z "$name" ] && continue
    if grep -q "^${name}$" "$EXCLUDE_LIST" 2>/dev/null; then continue; fi
    if is_file_in_excluded_dir "$name"; then continue; fi
    total_size=$((total_size + size))
    total_files=$((total_files + 1))
  done < "$BUILD_FILES_LIST"
  echo "$total_size|$total_files"
}

# -----------------------------------------------------------------------------
# FILESYSTEM NAVIGATION FOR INCLUSION
# -----------------------------------------------------------------------------
navigate_filesystem_for_inclusion() {
  echo ""
  echo "=== Navigate Filesystem to Include Files/Directories ==="
  echo "This allows you to add files that exist on disk but may be in .gitignore"
  echo "Hidden files and directories (starting with .) are shown"
  echo ""
  local current_dir="$REPO_DIR"

  while true; do
    clear
    echo "=== File System Navigation for Inclusion ==="
    echo "Current directory: $current_dir"
    echo ""
    case "$current_dir" in
      "${REPO_DIR}"*) ;;
      *) echo "Warning: You are outside the repository root!"; echo "" ;;
    esac

    local NAV_ITEMS="/tmp/build_nav_items_$$.txt"
    : > "$NAV_ITEMS"

    local item_num=1
    if [ "$current_dir" != "/" ]; then
      echo "  0. [..] Go to parent directory"
      echo ""
    fi

    # directories
    for item in "$current_dir"/* "$current_dir"/.*; do
      [ ! -e "$item" ] && continue
      local base=$(basename "$item")
      [ "$base" = "." ] && continue
      [ "$base" = ".." ] && continue
      [ "$base" = ".git" ] && continue
      if [ -d "$item" ]; then
        local file_count=$(find "$item" -type f 2>/dev/null | wc -l)
        local dir_size=$(du -sh "$item" 2>/dev/null | awk '{print $1}')
        printf "  %2s. [DIR]  %-8s %s/ (%s files)\n" "$item_num" "$dir_size" "$base" "$file_count"
        echo "${item_num}|DIR|${item}" >> "$NAV_ITEMS"
        item_num=$((item_num + 1))
      fi
    done

    # files
    for item in "$current_dir"/* "$current_dir"/.*; do
      [ ! -e "$item" ] && continue
      local base=$(basename "$item")
      [ "$base" = "." ] && continue
      [ "$base" = ".." ] && continue
      [ "$base" = ".git" ] && continue
      if [ -f "$item" ]; then
        local file_size=$(wc -c < "$item" 2>/dev/null || echo 0)
        local size_display=$(format_file_size "$file_size")
        local relative_to_repo="${item#$REPO_DIR/}"
        local gitignored=""
        if [ "$relative_to_repo" != "$item" ] && command -v git >/dev/null 2>&1 && git check-ignore -q "$relative_to_repo" 2>/dev/null; then
          gitignored="[GITIGNORED]"
        fi
        local already=""
        if [ -f "$BUILD_INCLUDE_LIST" ] && grep -q "^${relative_to_repo}$" "$BUILD_INCLUDE_LIST" 2>/dev/null; then
          already="[ALREADY INCLUDED]"
        fi
        printf "  %2s. [FILE] %8s %s %s %s\n" "$item_num" "$size_display" "$base" "$gitignored" "$already"
        echo "${item_num}|FILE|${item}" >> "$NAV_ITEMS"
        item_num=$((item_num + 1))
      fi
    done

    echo ""
    echo "Current included files:"
    if [ -s "$BUILD_INCLUDE_LIST" ]; then
      local count=0
      while IFS= read -r f; do
        count=$((count + 1))
        [ $count -le 5 ] && echo "  $f"
      done < "$BUILD_INCLUDE_LIST"
      local total=$(wc -l < "$BUILD_INCLUDE_LIST")
      [ "$total" -gt 5 ] && echo "  ... and $((total - 5)) more"
    else
      echo "  (none)"
    fi

    echo ""
    echo "Commands:"
    echo "  <number> = Enter directory or add file to include list"
    echo "  r <number> = Remove file from include list"
    echo "  c = Clear all included files"
    echo "  g = Go to specific path"
    echo "  b = Back to main menu"
    printf "Choice: "
    read choice
    case "$choice" in
      b|B) rm -f "$NAV_ITEMS"; break ;;
      c|C) : > "$BUILD_INCLUDE_LIST"; echo "All included files cleared."; sleep 1 ;;
      g|G)
        printf "Enter path: "; read custom_path
        if [ -n "$custom_path" ]; then
          case "$custom_path" in
            /*) ;;
            *) custom_path="$current_dir/$custom_path" ;;
          esac
          [ -d "$custom_path" ] && current_dir="$custom_path" || { echo "Directory not found"; sleep 1; }
        fi
        ;;
      r*)
        local remove_num=$(echo "$choice" | sed 's/^r//' | tr -d ' ')
        if [ -n "$remove_num" ] && [ -s "$BUILD_INCLUDE_LIST" ]; then
          local line=$(sed -n "${remove_num}p" "$BUILD_INCLUDE_LIST")
          if [ -n "$line" ]; then
            grep -v "^${line}$" "$BUILD_INCLUDE_LIST" > "${BUILD_INCLUDE_LIST}.tmp"
            mv "${BUILD_INCLUDE_LIST}.tmp" "$BUILD_INCLUDE_LIST"
            echo "Removed: $line"; sleep 1
          fi
        fi
        ;;
      *)
        if echo "$choice" | grep -q '^[0-9]\+$'; then
          if [ "$choice" = "0" ] && [ "$current_dir" != "/" ]; then
            current_dir=$(dirname "$current_dir")
          else
            local selected=$(grep "^${choice}|" "$NAV_ITEMS" 2>/dev/null)
            if [ -n "$selected" ]; then
              local type=$(echo "$selected" | cut -d'|' -f2)
              local path=$(echo "$selected" | cut -d'|' -f3)
              if [ "$type" = "DIR" ]; then
                current_dir="$path"
              else
                local rel="${path#$REPO_DIR/}"
                if [ "$rel" = "$path" ]; then rel="$path"; fi
                if grep -q "^${rel}$" "$BUILD_INCLUDE_LIST" 2>/dev/null; then
                  echo "Already in include list"
                else
                  echo "$rel" >> "$BUILD_INCLUDE_LIST"
                  echo "Added: $rel"
                fi
                sleep 1
              fi
            fi
          fi
        fi
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# BUILD CONFIGURATION INTERFACE
# -----------------------------------------------------------------------------
build_config_interface() {
  echo ""
  echo "========================================="
  echo "  BUILD CONFIGURATION"
  echo "========================================="
  echo ""
  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository"
    return 1
  fi

  EXCLUDE_LIST="/tmp/build_exclude_$$.txt"
  EXCLUDE_DIRS_LIST="/tmp/build_exclude_dirs_$$.txt"
  : > "$EXCLUDE_LIST"
  : > "$EXCLUDE_DIRS_LIST"
  : > "$BUILD_INCLUDE_LIST"

  BUILD_FILES_LIST="/tmp/build_files_$$.txt"
  BUILD_DIRS_LIST="/tmp/build_dirs_$$.txt"
  : > "$BUILD_FILES_LIST"
  : > "$BUILD_DIRS_LIST"

  SELECTED_COMMIT=""
  SELECTED_COMMIT_MSG=""
  COMMIT_CACHE="/tmp/build_commits_cache_$$.txt"
  MONTH_CACHE="/tmp/build_months_cache_$$.txt"

  load_files_from_commit() {
    local commit="$1"
    : > "$BUILD_FILES_LIST"
    : > "$BUILD_DIRS_LIST"
    if [ -z "$commit" ]; then
      # Current working tree
      git ls-files -z 2>/dev/null | while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
          size=$(wc -c < "$file" 2>/dev/null || echo 0)
        else
          size=0
        fi
        case "$file" in
          *.js|*.sh|*.py|*.rb|*.php|*.ts|*.jsx|*.tsx|*.css|*.html|*.json|*.xml|*.yml|*.yaml|*.md|*.txt|*.conf|*.cfg|*.ini)
            printf "%s|%s|C\n" "$size" "$file" ;;
          *) printf "%s|%s|D\n" "$size" "$file" ;;
        esac
      done | sort -t'|' -k1 -n -r > "$BUILD_FILES_LIST"
    else
      git ls-tree -r "$commit" 2>/dev/null | while read -r mode type hash filename; do
        [ "$type" != "blob" ] && continue
        size=$(git cat-file -s "$hash" 2>/dev/null || echo 0)
        case "$filename" in
          *.js|*.sh|*.py|*.rb|*.php|*.ts|*.jsx|*.tsx|*.css|*.html|*.json|*.xml|*.yml|*.yaml|*.md|*.txt|*.conf|*.cfg|*.ini) file_type="C" ;;
          *) file_type="D" ;;
        esac
        echo "${size}|${filename}|${file_type}" >> /tmp/build_files_temp_$$.txt
      done
      [ -s /tmp/build_files_temp_$$.txt ] && sort -t'|' -k1 -n -r /tmp/build_files_temp_$$.txt > "$BUILD_FILES_LIST"
      rm -f /tmp/build_files_temp_$$.txt
    fi

    # build dirs list
    local temp_dirs="/tmp/build_dirs_temp_$$.txt"
    : > "$temp_dirs"
    while IFS='|' read -r size filename ftype; do
      [ -z "$filename" ] && continue
      dirname "$filename"
    done < "$BUILD_FILES_LIST" | sort -u > "$temp_dirs"
    local top_level=0
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      [ "$d" = "." ] && continue
      case "$d" in
        */*) ;;
        *) top_level=$((top_level+1)) ;;
      esac
    done < "$temp_dirs"
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      [ "$d" = "." ] && continue
      if [ "$top_level" -eq 1 ]; then
        case "$d" in */*) ;; *) continue ;; esac
      fi
      local dir_info=$(grep "|${d}/" "$BUILD_FILES_LIST" 2>/dev/null | awk -F'|' '{sum+=$1; count++} END {printf "%d|%d", sum+0, count+0}')
      local dir_size=$(echo "$dir_info" | cut -d'|' -f1)
      local file_count=$(echo "$dir_info" | cut -d'|' -f2)
      echo "${dir_size}|${d}|${file_count}" >> "$BUILD_DIRS_LIST"
    done < "$temp_dirs"
    [ -s "$BUILD_DIRS_LIST" ] && sort -t'|' -k1 -n -r "$BUILD_DIRS_LIST" -o "$BUILD_DIRS_LIST"
    rm -f "$temp_dirs"
  }

  load_files_from_commit ""

  build_month_cache() {
    : > "$MONTH_CACHE"
    if [ -f "$COMMIT_CACHE" ]; then
      while IFS='|' read -r csize hash date msg is_version; do
        [ -z "$hash" ] && continue
        echo "$date" | cut -d'-' -f1-2 >> /tmp/build_months_raw_$$.txt
      done < "$COMMIT_CACHE"
      sort -ru /tmp/build_months_raw_$$.txt | while IFS= read -r ym; do
        local year=$(echo "$ym" | cut -d'-' -f1)
        local month=$(echo "$ym" | cut -d'-' -f2)
        case "$month" in
          01) month_name="January";; 02) month_name="February";; 03) month_name="March";;
          04) month_name="April";; 05) month_name="May";; 06) month_name="June";;
          07) month_name="July";; 08) month_name="August";; 09) month_name="September";;
          10) month_name="October";; 11) month_name="November";; 12) month_name="December";;
          *) month_name="Unknown";;
        esac
        local commit_count=$(grep "^[^|]*|[^|]*|${ym}-" "$COMMIT_CACHE" | wc -l)
        echo "${ym}|${year}|${month_name}|${commit_count}" >> "$MONTH_CACHE"
      done
      rm -f /tmp/build_months_raw_$$.txt
    fi
  }

  # Main loop
  while true; do
    clear
    local stats=$(calculate_build_stats)
    local build_size=$(echo "$stats" | cut -d'|' -f1)
    local build_file_count=$(echo "$stats" | cut -d'|' -f2)
    local excl_files=$(wc -l < "$EXCLUDE_LIST" 2>/dev/null || echo 0)
    local excl_dirs=$(wc -l < "$EXCLUDE_DIRS_LIST" 2>/dev/null || echo 0)
    local incl_files=$(wc -l < "$BUILD_INCLUDE_LIST" 2>/dev/null || echo 0)

    echo "=== BUILD CONFIGURATION ==="
    if [ -z "$SELECTED_COMMIT" ]; then echo "Source: HEAD (current working tree)"; else
      short_hash=$(echo "$SELECTED_COMMIT" | cut -c1-7)
      shortened_msg=$(echo "$SELECTED_COMMIT_MSG" | cut -c1-30)
      echo "Source: ${short_hash} ${shortened_msg}"
    fi
    echo "Output: $([ "$BUILD_TAR" = true ] && echo "Tar.gz" || echo "Directory") | Size: $(format_file_size "$build_size") | Files: $build_file_count | Excl: ${excl_files}f/${excl_dirs}d | InclFS: ${incl_files}"
    echo ""
    if [ -s "$EXCLUDE_DIRS_LIST" ] || [ -s "$EXCLUDE_LIST" ]; then
      echo "Excluded:"
      if [ -s "$EXCLUDE_DIRS_LIST" ]; then
        local count=0
        while IFS= read -r d; do
          count=$((count+1)); [ $count -le 2 ] && echo "  dir: $d"
        done < "$EXCLUDE_DIRS_LIST"
        local total=$(wc -l < "$EXCLUDE_DIRS_LIST"); [ "$total" -gt 2 ] && echo "  ... and $((total-2)) more dirs"
      fi
      if [ -s "$EXCLUDE_LIST" ]; then
        local count=0
        while IFS= read -r f; do
          count=$((count+1)); [ $count -le 2 ] && echo "  file: $f"
        done < "$EXCLUDE_LIST"
        local total=$(wc -l < "$EXCLUDE_LIST"); [ "$total" -gt 2 ] && echo "  ... and $((total-2)) more files"
      fi
    else
      echo "No exclusions"
    fi
    if [ -s "$BUILD_INCLUDE_LIST" ]; then
      echo "Included from filesystem:"
      local count=0
      while IFS= read -r f; do
        count=$((count+1)); [ $count -le 3 ] && echo "  + $f"
      done < "$BUILD_INCLUDE_LIST"
      [ "$incl_files" -gt 3 ] && echo "  ... and $((incl_files-3)) more"
    fi

    echo ""
    echo "Actions:"
    echo "1. Exclude directories"
    echo "2. Exclude files"
    echo "3. Search and exclude"
    echo "4. Remove files from exclusion"
    echo "5. Remove directories from exclusion"
    echo "6. Clear all exclusions"
    echo "7. Change source commit"
    echo "8. Toggle output format ($([ "$BUILD_TAR" = true ] && echo "Tar.gz" || echo "Directory"))"
    echo "9. Navigate filesystem to INCLUDE files"
    echo "s. Save config | l. Load config | d. Delete config"
    echo "0. Done | q. Quit"
    printf "Choice: "
    read action

    case "$action" in
      1) # Exclude directories
         current_page=1; ITEMS_PER_PAGE=5
         while true; do
           AVAILABLE_DIRS="/tmp/build_available_dirs_$$.txt"; : > "$AVAILABLE_DIRS"
           EXCLUDED_FILES_SET="/tmp/build_excluded_files_set_$$.txt"; : > "$EXCLUDED_FILES_SET"
           [ -s "$EXCLUDE_LIST" ] && while IFS= read -r f; do echo "$f"; done < "$EXCLUDE_LIST" > "$EXCLUDED_FILES_SET"
           [ -s "$EXCLUDE_DIRS_LIST" ] && while IFS='|' read -r fsize fname ftype; do
             while IFS= read -r ed; do case "$fname" in ${ed}/*|${ed}) echo "$fname"; break;; esac; done < "$EXCLUDE_DIRS_LIST"
           done < "$BUILD_FILES_LIST" | sort -u > "$EXCLUDED_FILES_SET"
           sort -u "$EXCLUDED_FILES_SET" -o "$EXCLUDED_FILES_SET"
           while IFS='|' read -r dir_size dir_name file_count; do
             [ -z "$dir_name" ] && continue
             grep -q "^${dir_name}$" "$EXCLUDE_DIRS_LIST" 2>/dev/null && continue
             local parent_excluded=false
             if [ -s "$EXCLUDE_DIRS_LIST" ]; then
               while IFS= read -r ed; do case "$dir_name" in ${ed}/*) parent_excluded=true; break;; esac; done < "$EXCLUDE_DIRS_LIST"
             fi
             [ "$parent_excluded" = true ] && continue
             local actual_size=0; local actual_count=0
             while IFS='|' read -r fsize fname ftype; do
               case "$fname" in ${dir_name}/*|${dir_name})
                 if ! grep -q "^${fname}$" "$EXCLUDED_FILES_SET" 2>/dev/null; then
                   actual_size=$((actual_size+fsize)); actual_count=$((actual_count+1))
                 fi ;;
               esac
             done < "$BUILD_FILES_LIST"
             [ "$actual_count" -gt 0 ] && echo "${actual_size}|${dir_name}|${actual_count}" >> "$AVAILABLE_DIRS"
           done < "$BUILD_DIRS_LIST"
           sort -t'|' -k1 -n -r "$AVAILABLE_DIRS" -o "$AVAILABLE_DIRS"
           local total_items=$(wc -l < "$AVAILABLE_DIRS")
           [ "$total_items" -eq 0 ] && echo "All directories already excluded!" && sleep 1 && break
           local total_pages=$(( (total_items + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
           [ "$current_page" -gt "$total_pages" ] && current_page="$total_pages"
           [ "$current_page" -lt 1 ] && current_page=1
           start_line=$(( (current_page - 1) * ITEMS_PER_PAGE + 1 )); end_line=$(( current_page * ITEMS_PER_PAGE ))
           clear
           echo "=== Select Directories to Exclude (${current_page}/${total_pages}) ==="
           line_num=0; counter=1
           while IFS='|' read -r dir_size dir_name file_count; do
             line_num=$((line_num+1)); [ "$line_num" -lt "$start_line" ] && continue; [ "$line_num" -gt "$end_line" ] && break
             [ -z "$dir_name" ] && continue
             printf "  %2s. %8s  %s (%s files)\n" "$counter" "$(format_file_size "$dir_size")" "$dir_name" "$file_count"
             counter=$((counter+1))
           done < "$AVAILABLE_DIRS"
           echo ""; echo "n=next p=previous b=back"
           printf "> "; read cmd
           case "$cmd" in
             n|N) [ "$current_page" -lt "$total_pages" ] && current_page=$((current_page+1)) ;;
             p|P) [ "$current_page" -gt 1 ] && current_page=$((current_page-1)) ;;
             b|B) break ;;
             *)
               if echo "$cmd" | grep -q '^[0-9]\+$'; then
                 line_num=0; counter=1; selected_dir=""
                 while IFS='|' read -r dir_size dir_name file_count; do
                   line_num=$((line_num+1)); [ "$line_num" -lt "$start_line" ] && continue; [ "$line_num" -gt "$end_line" ] && break
                   [ "$counter" = "$cmd" ] && selected_dir="$dir_name" && break
                   counter=$((counter+1))
                 done < "$AVAILABLE_DIRS"
                 if [ -n "$selected_dir" ]; then
                   echo "$selected_dir" >> "$EXCLUDE_DIRS_LIST"
                   local tmp_excl_dirs="/tmp/build_tmp_excl_dirs_$$.txt"; : > "$tmp_excl_dirs"
                   while IFS= read -r ed; do case "$ed" in ${selected_dir}/*) ;; *) echo "$ed" >> "$tmp_excl_dirs";; esac; done < "$EXCLUDE_DIRS_LIST"
                   mv "$tmp_excl_dirs" "$EXCLUDE_DIRS_LIST"
                   local tmp_excl_files="/tmp/build_tmp_excl_files_$$.txt"; : > "$tmp_excl_files"
                   while IFS= read -r ef; do case "$ef" in ${selected_dir}/*|${selected_dir}) ;; *) echo "$ef" >> "$tmp_excl_files";; esac; done < "$EXCLUDE_LIST"
                   mv "$tmp_excl_files" "$EXCLUDE_LIST"
                   echo "Excluded directory: $selected_dir"; sleep 0.5
                 fi
               fi ;;
           esac
         done
         rm -f "$AVAILABLE_DIRS" "$EXCLUDED_FILES_SET"
         ;;
      2) # Exclude files
         current_page=1; ITEMS_PER_PAGE=5
         while true; do
           AVAILABLE_LIST="/tmp/build_available_$$.txt"; : > "$AVAILABLE_LIST"
           EXCLUDED_FILES_SET="/tmp/build_excluded_files_set_$$.txt"; : > "$EXCLUDED_FILES_SET"
           [ -s "$EXCLUDE_LIST" ] && while IFS= read -r f; do echo "$f"; done < "$EXCLUDE_LIST" >> "$EXCLUDED_FILES_SET"
           [ -s "$EXCLUDE_DIRS_LIST" ] && while IFS='|' read -r fsize fname ftype; do
             while IFS= read -r ed; do case "$fname" in ${ed}/*|${ed}) echo "$fname"; break;; esac; done < "$EXCLUDE_DIRS_LIST"
           done < "$BUILD_FILES_LIST" >> "$EXCLUDED_FILES_SET"
           sort -u "$EXCLUDED_FILES_SET" -o "$EXCLUDED_FILES_SET"
           while IFS='|' read -r size_bytes filename file_type; do
             [ -z "$filename" ] && continue
             grep -q "^${filename}$" "$EXCLUDE_LIST" 2>/dev/null && continue
             if ! grep -q "^${filename}$" "$EXCLUDED_FILES_SET" 2>/dev/null; then
               echo "${size_bytes}|${filename}|NORMAL" >> "$AVAILABLE_LIST"
             fi
           done < "$BUILD_FILES_LIST"
           local total_items=$(wc -l < "$AVAILABLE_LIST")
           [ "$total_items" -eq 0 ] && echo "All files already excluded!" && sleep 1 && break
           local total_pages=$(( (total_items + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
           [ "$current_page" -gt "$total_pages" ] && current_page="$total_pages"
           [ "$current_page" -lt 1 ] && current_page=1
           start_line=$(( (current_page - 1) * ITEMS_PER_PAGE + 1 )); end_line=$(( current_page * ITEMS_PER_PAGE ))
           clear
           echo "=== Select Files to Exclude (${current_page}/${total_pages}) ==="
           line_num=0; counter=1
           while IFS='|' read -r size_bytes filename status; do
             line_num=$((line_num+1)); [ "$line_num" -lt "$start_line" ] && continue; [ "$line_num" -gt "$end_line" ] && break
             [ -z "$filename" ] && continue
             printf "  %2s. %8s  %s\n" "$counter" "$(format_file_size "$size_bytes")" "$filename"
             counter=$((counter+1))
           done < "$AVAILABLE_LIST"
           echo ""; echo "n=next p=previous b=back"
           printf "> "; read cmd
           case "$cmd" in
             n|N) [ "$current_page" -lt "$total_pages" ] && current_page=$((current_page+1)) ;;
             p|P) [ "$current_page" -gt 1 ] && current_page=$((current_page-1)) ;;
             b|B) break ;;
             *)
               if echo "$cmd" | grep -q '^[0-9]\+$'; then
                 line_num=0; counter=1; selected_file=""
                 while IFS='|' read -r size_bytes filename status; do
                   line_num=$((line_num+1)); [ "$line_num" -lt "$start_line" ] && continue; [ "$line_num" -gt "$end_line" ] && break
                   [ "$counter" = "$cmd" ] && selected_file="$filename" && break
                   counter=$((counter+1))
                 done < "$AVAILABLE_LIST"
                 if [ -n "$selected_file" ]; then
                   echo "$selected_file" >> "$EXCLUDE_LIST"
                   echo "Excluded: $selected_file"; sleep 0.5
                 fi
               fi ;;
           esac
         done
         rm -f "$AVAILABLE_LIST" "$EXCLUDED_FILES_SET"
         ;;
      3) # Search and exclude
         clear; echo "=== Search Files to Exclude ==="
         printf "Enter search term: "; read search_term
         if [ -n "$search_term" ]; then
           SEARCH_RESULTS="/tmp/build_search_$$.txt"; : > "$SEARCH_RESULTS"
           while IFS='|' read -r size_bytes filename file_type; do
             case "$filename" in *"$search_term"*)
               grep -q "^${filename}$" "$EXCLUDE_LIST" 2>/dev/null || echo "${size_bytes}|${filename}" >> "$SEARCH_RESULTS"
             ;; esac
           done < "$BUILD_FILES_LIST"
           local result_count=$(wc -l < "$SEARCH_RESULTS")
           if [ "$result_count" -eq 0 ]; then
             echo "No matching files found."; sleep 1
           else
             echo "Found $result_count matching files:"
             counter=1
             while IFS='|' read -r size_bytes filename; do
               printf "  %2s. %8s  %s\n" "$counter" "$(format_file_size "$size_bytes")" "$filename"
               counter=$((counter+1))
             done < "$SEARCH_RESULTS"
             echo "Enter number to exclude | a=exclude all | b=back"
             printf "> "; read search_cmd
             case "$search_cmd" in
               a|A) while IFS='|' read -r size_bytes filename; do echo "$filename"; done < "$SEARCH_RESULTS" >> "$EXCLUDE_LIST"; echo "All excluded!"; sleep 1 ;;
               b|B) ;;
               *)
                 if echo "$search_cmd" | grep -q '^[0-9]\+$'; then
                   counter=1
                   while IFS='|' read -r size_bytes filename; do
                     [ "$counter" = "$search_cmd" ] && echo "$filename" >> "$EXCLUDE_LIST" && echo "Excluded: $filename" && sleep 0.5 && break
                     counter=$((counter+1))
                   done < "$SEARCH_RESULTS"
                 fi ;;
             esac
           fi
           rm -f "$SEARCH_RESULTS"
         fi ;;
      4) # Remove file exclusions
         if [ ! -s "$EXCLUDE_LIST" ]; then echo "No file exclusions."; sleep 1; else
           clear; echo "=== Remove Files from Exclusion ==="
           counter=1; : > /tmp/build_remove_$$.txt
           while IFS= read -r f; do
             printf "  %2s. %s\n" "$counter" "$f"
             echo "${counter}|${f}" >> /tmp/build_remove_$$.txt
             counter=$((counter+1))
           done < "$EXCLUDE_LIST"
           echo "Enter number | a=remove all | b=back"
           printf "> "; read cmd
           case "$cmd" in
             a|A) : > "$EXCLUDE_LIST"; echo "All file exclusions removed"; sleep 1 ;;
             b|B) ;;
             *)
               if echo "$cmd" | grep -q '^[0-9]\+$'; then
                 local f=$(grep "^${cmd}|" /tmp/build_remove_$$.txt | cut -d'|' -f2)
                 [ -n "$f" ] && grep -v "^${f}$" "$EXCLUDE_LIST" > "${EXCLUDE_LIST}.tmp" && mv "${EXCLUDE_LIST}.tmp" "$EXCLUDE_LIST" && echo "Removed: $f" && sleep 0.5
               fi ;;
           esac
           rm -f /tmp/build_remove_$$.txt
         fi ;;
      5) # Remove dir exclusions
         if [ ! -s "$EXCLUDE_DIRS_LIST" ]; then echo "No directory exclusions."; sleep 1; else
           clear; echo "=== Remove Directories from Exclusion ==="
           counter=1; : > /tmp/build_remove_dirs_$$.txt
           while IFS= read -r d; do
             printf "  %2s. %s\n" "$counter" "$d"
             echo "${counter}|${d}" >> /tmp/build_remove_dirs_$$.txt
             counter=$((counter+1))
           done < "$EXCLUDE_DIRS_LIST"
           echo "Enter number | a=remove all | b=back"
           printf "> "; read cmd
           case "$cmd" in
             a|A) : > "$EXCLUDE_DIRS_LIST"; : > "$EXCLUDE_LIST"; echo "All exclusions removed"; sleep 1 ;;
             b|B) ;;
             *)
               if echo "$cmd" | grep -q '^[0-9]\+$'; then
                 local d=$(grep "^${cmd}|" /tmp/build_remove_dirs_$$.txt | cut -d'|' -f2)
                 [ -n "$d" ] && grep -v "^${d}$" "$EXCLUDE_DIRS_LIST" > "${EXCLUDE_DIRS_LIST}.tmp" && mv "${EXCLUDE_DIRS_LIST}.tmp" "$EXCLUDE_DIRS_LIST" && echo "Removed: $d" && sleep 0.5
               fi ;;
           esac
           rm -f /tmp/build_remove_dirs_$$.txt
         fi ;;
      6) : > "$EXCLUDE_LIST"; : > "$EXCLUDE_DIRS_LIST"; : > "$BUILD_INCLUDE_LIST"; echo "All exclusions cleared"; sleep 1 ;;
      7) # Change source commit
         if [ ! -f "$COMMIT_CACHE" ]; then
           echo "Building commit cache..."
           git log --all --format="%H|%ai|%s" 2>/dev/null | while IFS='|' read -r hash date msg; do
             local commit_size=$(git ls-tree -r -l "$hash" 2>/dev/null | awk '{if ($4 ~ /^[0-9]+$/) sum += $4} END {print sum+0}')
             local is_version=" "; case "$msg" in *[!0-9.]*) ;; *) case "$msg" in *.*) is_version="V";; esac;; esac
             echo "${commit_size}|${hash}|$(echo "$date" | cut -d' ' -f1)|${msg}|${is_version}"
           done | sort -t'|' -k3 -r > "$COMMIT_CACHE"
           build_month_cache
         fi
         current_page=1; ITEMS_PER_PAGE=5; show_versions_only=false; date_filter=""
         while true; do
           local FILTERED="/tmp/build_filtered_$$.txt"; : > "$FILTERED"
           while IFS='|' read -r csize hash date msg isver; do
             [ "$show_versions_only" = true ] && [ "$isver" != "V" ] && continue
             [ -n "$date_filter" ] && case "$date" in ${date_filter}*) ;; *) continue;; esac
             echo "${csize}|${hash}|${date}|${msg}|${isver}" >> "$FILTERED"
           done < "$COMMIT_CACHE"
           local total=$(wc -l < "$FILTERED")
           if [ "$total" -eq 0 ]; then echo "No commits with filters."; date_filter=""; continue; fi
           local pages=$(( (total + ITEMS_PER_PAGE -1) / ITEMS_PER_PAGE ))
           [ "$current_page" -gt "$pages" ] && current_page="$pages"
           start_line=$(( (current_page-1)*ITEMS_PER_PAGE+1 )); end_line=$(( current_page*ITEMS_PER_PAGE ))
           clear
           echo "=== Select Source Commit (${current_page}/${pages}) ==="
           line_num=0; counter=1
           : > /tmp/build_commit_map_$$.txt
           while IFS='|' read -r csize hash date msg isver; do
             line_num=$((line_num+1)); [ "$line_num" -lt "$start_line" ] && continue; [ "$line_num" -gt "$end_line" ] && break
             short_hash=$(echo "$hash" | cut -c1-7)
             short_msg=$(echo "$msg" | cut -c1-30)
             marker=""; [ -n "$SELECTED_COMMIT" ] && [ "$hash" = "$SELECTED_COMMIT" ] && marker=" << SELECTED"
             printf "  %2s. %8s %s %s %s%s\n" "$counter" "$(format_file_size "$csize")" "$short_hash" "$date" "$short_msg" "$marker"
             echo "${counter}|${hash}|${msg}" >> /tmp/build_commit_map_$$.txt
             counter=$((counter+1))
           done < "$FILTERED"
           echo "n=next p=previous v=versions a=all m=month c=HEAD b=back"
           printf "> "; read cmd
           case "$cmd" in
             n|N) [ "$current_page" -lt "$pages" ] && current_page=$((current_page+1)) ;;
             p|P) [ "$current_page" -gt 1 ] && current_page=$((current_page-1)) ;;
             v|V) show_versions_only=true; date_filter=""; current_page=1 ;;
             a|A) show_versions_only=false; date_filter=""; current_page=1 ;;
             m|M)
               while IFS='|' read -r ym year month_name commit_count; do
                 echo "  $ym $month_name $year ($commit_count commits)"
               done < "$MONTH_CACHE" | head -10
               printf "Enter month (YYYY-MM) or empty to clear: "; read month_sel
               if [ -z "$month_sel" ]; then date_filter=""; current_page=1;
               else
                 grep -q "^${month_sel}|" "$MONTH_CACHE" && date_filter="$month_sel" && current_page=1
               fi ;;
             c|C) SELECTED_COMMIT=""; SELECTED_COMMIT_MSG=""; date_filter=""; : > "$EXCLUDE_LIST"; : > "$EXCLUDE_DIRS_LIST"; load_files_from_commit ""; echo "Switched to HEAD"; sleep 1; break ;;
             b|B) break ;;
             *)
               if echo "$cmd" | grep -q '^[0-9]\+$'; then
                 local sel=$(grep "^${cmd}|" /tmp/build_commit_map_$$.txt | head -1)
                 if [ -n "$sel" ]; then
                   SELECTED_COMMIT=$(echo "$sel" | cut -d'|' -f2)
                   SELECTED_COMMIT_MSG=$(echo "$sel" | cut -d'|' -f3)
                   : > "$EXCLUDE_LIST"; : > "$EXCLUDE_DIRS_LIST"; load_files_from_commit "$SELECTED_COMMIT"
                   echo "Switched to commit: $SELECTED_COMMIT_MSG"; sleep 1; break
                 fi
               fi ;;
           esac
           rm -f /tmp/build_commit_map_$$.txt
         done
         rm -f "$FILTERED" ;;
      8) if [ "$BUILD_TAR" = true ]; then BUILD_TAR=false; else BUILD_TAR=true; fi; sleep 1 ;;
      9) navigate_filesystem_for_inclusion ;;
      s|S)
        clear; echo "=== Save Build Configuration ==="
        list_saved_configurations || echo "No saved configurations yet."
        printf "Enter save name: "; read save_name
        [ -n "$save_name" ] && save_name=$(echo "$save_name" | sed 's/[^a-zA-Z0-9_-]/_/g') && save_build_configuration "$save_name" && sleep 1
        ;;
      l|L)
        clear; echo "=== Load Build Configuration ==="
        local save_num=1
        if [ -f "$BUILD_SAVE_FILE" ]; then
          while IFS= read -r line; do
            case "$line" in
              \[SAVE:*) name=$(echo "$line" | sed 's/^\[SAVE://;s/\]$//')
                printf "  %2s. %s\n" "$save_num" "$name"
                save_num=$((save_num+1)) ;;
            esac
          done < "$BUILD_SAVE_FILE"
        fi
        total_saves=$((save_num-1))
        [ "$total_saves" -eq 0 ] && echo "No saved configurations." && sleep 1 && continue
        printf "Enter number or name (b=cancel): "; read load_input
        if [ "$load_input" != "b" ] && [ -n "$load_input" ]; then
          local load_name=""
          if echo "$load_input" | grep -q '^[0-9]\+$'; then
            load_name=$(grep -n '^\[' "$BUILD_SAVE_FILE" | sed -n "${load_input}p" | sed 's/.*\[SAVE:\(.*\)\].*/\1/')
          else
            load_name="$load_input"
            grep -q "^\[SAVE:${load_name}\]$" "$BUILD_SAVE_FILE" || { echo "Save not found"; sleep 1; continue; }
          fi
          if load_build_configuration "$load_name"; then
            if [ -n "$BUILD_SELECTED_COMMIT" ]; then
              load_files_from_commit "$BUILD_SELECTED_COMMIT"
            else
              load_files_from_commit ""
            fi
            echo "Loaded configuration: $load_name"; sleep 1
          fi
        fi
        ;;
      d|D)
        clear; echo "=== Delete Build Configuration ==="
        local save_num=1
        if [ -f "$BUILD_SAVE_FILE" ]; then
          while IFS= read -r line; do
            case "$line" in
              \[SAVE:*) name=$(echo "$line" | sed 's/^\[SAVE://;s/\]$//')
                printf "  %2s. %s\n" "$save_num" "$name"
                save_num=$((save_num+1)) ;;
            esac
          done < "$BUILD_SAVE_FILE"
        fi
        total_saves=$((save_num-1))
        [ "$total_saves" -eq 0 ] && echo "No saved configurations." && sleep 1 && continue
        printf "Enter number or name (b=cancel): "; read del_input
        if [ "$del_input" != "b" ] && [ -n "$del_input" ]; then
          local del_name=""
          if echo "$del_input" | grep -q '^[0-9]\+$'; then
            del_name=$(grep -n '^\[' "$BUILD_SAVE_FILE" | sed -n "${del_input}p" | sed 's/.*\[SAVE:\(.*\)\].*/\1/')
          else
            del_name="$del_input"
          fi
          printf "Delete '%s'? (y/n): " "$del_name"; read confirm
          if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            delete_saved_configuration "$del_name" && sleep 1
          fi
        fi
        ;;
      0) break ;;
      q|Q) rm -f "$EXCLUDE_LIST" "$EXCLUDE_DIRS_LIST" "$BUILD_INCLUDE_LIST" "$BUILD_FILES_LIST" "$BUILD_DIRS_LIST" "$COMMIT_CACHE" "$MONTH_CACHE"; echo "Build cancelled."; exit 0 ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done

  BUILD_SELECTED_COMMIT="$SELECTED_COMMIT"
  BUILD_SELECTED_COMMIT_MSG="$SELECTED_COMMIT_MSG"
  clear
  echo "=== FINAL BUILD SUMMARY ==="
  echo "Source: $([ -z "$SELECTED_COMMIT" ] && echo "HEAD" || echo "$SELECTED_COMMIT_MSG")"
  echo "Output: $([ "$BUILD_TAR" = true ] && echo "Tar.gz" || echo "Directory")"
  local final_stats=$(calculate_build_stats)
  echo "Size: $(format_file_size $(echo "$final_stats" | cut -d'|' -f1)) | Files: $(echo "$final_stats" | cut -d'|' -f2)"
  echo "Excluded: $(wc -l < "$EXCLUDE_LIST") files, $(wc -l < "$EXCLUDE_DIRS_LIST") directories"
  echo "Included from filesystem: $(wc -l < "$BUILD_INCLUDE_LIST") files"
  rm -f "$BUILD_FILES_LIST" "$BUILD_DIRS_LIST" "$COMMIT_CACHE" "$MONTH_CACHE"
  return 0
}

# -----------------------------------------------------------------------------
# SAVE/LOAD CONFIGURATION
# -----------------------------------------------------------------------------
save_build_configuration() {
  local save_name="$1"
  local tmp_file="${BUILD_SAVE_FILE}.tmp.$$"
  if [ -f "$BUILD_SAVE_FILE" ]; then
    local skip=false
    while IFS= read -r line; do
      case "$line" in
        "[SAVE:${save_name}]") skip=true; continue ;;
        "[/SAVE:${save_name}]") skip=false; continue ;;
      esac
      if [ "$skip" = false ]; then echo "$line" >> "$tmp_file"; fi
    done < "$BUILD_SAVE_FILE"
  else
    : > "$tmp_file"
  fi
  {
    echo "[SAVE:${save_name}]"
    echo "DATE=$(date)"
    echo "TAR=${BUILD_TAR}"
    echo "COMMIT=${BUILD_SELECTED_COMMIT:-HEAD}"
    echo "COMMIT_MESSAGE=${BUILD_SELECTED_COMMIT_MSG:-HEAD}"
    echo "EXCLUDED_FILES_COUNT=$(wc -l < "$EXCLUDE_LIST" 2>/dev/null || echo 0)"
    echo "EXCLUDED_DIRECTORIES_COUNT=$(wc -l < "$EXCLUDE_DIRS_LIST" 2>/dev/null || echo 0)"
    echo "INCLUDED_FILES_COUNT=$(wc -l < "$BUILD_INCLUDE_LIST" 2>/dev/null || echo 0)"
    if [ -s "$EXCLUDE_LIST" ]; then
      while IFS= read -r f; do [ -n "$f" ] && echo "EXCLUDED_FILE=${f}"; done < "$EXCLUDE_LIST"
    fi
    if [ -s "$EXCLUDE_DIRS_LIST" ]; then
      while IFS= read -r d; do [ -n "$d" ] && echo "EXCLUDED_DIRECTORY=${d}"; done < "$EXCLUDE_DIRS_LIST"
    fi
    if [ -s "$BUILD_INCLUDE_LIST" ]; then
      while IFS= read -r f; do [ -n "$f" ] && echo "INCLUDED_FILE=${f}"; done < "$BUILD_INCLUDE_LIST"
    fi
    echo "[/SAVE:${save_name}]"
  } >> "$tmp_file"
  mv "$tmp_file" "$BUILD_SAVE_FILE"
  echo "Build configuration saved as: $save_name"
  return 0
}

load_build_configuration() {
  local save_name="$1"
  [ ! -f "$BUILD_SAVE_FILE" ] && echo "Error: No saves file found" && return 1
  grep -q "^\[SAVE:${save_name}\]$" "$BUILD_SAVE_FILE" || { echo "Save '$save_name' not found"; return 1; }

  local tmp_excl="/tmp/build_load_excl_$$.txt"
  local tmp_dir="/tmp/build_load_dir_$$.txt"
  local tmp_incl="/tmp/build_load_incl_$$.txt"
  : > "$tmp_excl"; : > "$tmp_dir"; : > "$tmp_incl"

  local in_section=false
  while IFS= read -r line; do
    case "$line" in
      "[SAVE:${save_name}]") in_section=true; continue ;;
      "[/SAVE:${save_name}]") in_section=false; break ;;
    esac
    if [ "$in_section" = true ]; then
      case "$line" in
        TAR=*) val=$(echo "$line" | cut -d= -f2-); if [ "$val" = "true" ]; then BUILD_TAR=true; else BUILD_TAR=false; fi ;;
        COMMIT=*) val=$(echo "$line" | cut -d= -f2-); if [ "$val" = "HEAD" ]; then BUILD_SELECTED_COMMIT=""; else BUILD_SELECTED_COMMIT="$val"; fi ;;
        COMMIT_MESSAGE=*) BUILD_SELECTED_COMMIT_MSG=$(echo "$line" | cut -d= -f2-) ;;
        EXCLUDED_FILE=*) echo "$line" | cut -d= -f2- >> "$tmp_excl" ;;
        EXCLUDED_DIRECTORY=*) echo "$line" | cut -d= -f2- >> "$tmp_dir" ;;
        INCLUDED_FILE=*) echo "$line" | cut -d= -f2- >> "$tmp_incl" ;;
      esac
    fi
  done < "$BUILD_SAVE_FILE"

  cp "$tmp_excl" "$EXCLUDE_LIST" 2>/dev/null || true
  cp "$tmp_dir" "$EXCLUDE_DIRS_LIST" 2>/dev/null || true
  cp "$tmp_incl" "$BUILD_INCLUDE_LIST" 2>/dev/null || true
  SAVED_INCLUDE_LIST="/tmp/build_include_saved_${save_name}.txt"
  cp "$tmp_incl" "$SAVED_INCLUDE_LIST" 2>/dev/null || true
  rm -f "$tmp_excl" "$tmp_dir" "$tmp_incl"

  echo "Loaded build configuration: $save_name"
  echo "  Output: $([ "$BUILD_TAR" = true ] && echo "Tar.gz" || echo "Directory")"
  echo "  Excluded files: $(wc -l < "$EXCLUDE_LIST")"
  echo "  Excluded directories: $(wc -l < "$EXCLUDE_DIRS_LIST")"
  echo "  Included from filesystem: $(wc -l < "$BUILD_INCLUDE_LIST")"
  return 0
}

list_saved_configurations() {
  [ ! -f "$BUILD_SAVE_FILE" ] && return 1
  local count=0
  while IFS= read -r line; do
    case "$line" in
      \[SAVE:*) name=$(echo "$line" | sed 's/^\[SAVE://;s/\]$//'); count=$((count+1)); printf "  %2s. %s\n" "$count" "$name" ;;
    esac
  done < "$BUILD_SAVE_FILE"
  return $count
}

delete_saved_configuration() {
  local save_name="$1"
  [ ! -f "$BUILD_SAVE_FILE" ] && return 1
  local tmp_file="${BUILD_SAVE_FILE}.tmp.$$"
  local skip=false
  while IFS= read -r line; do
    case "$line" in
      "[SAVE:${save_name}]") skip=true; continue ;;
      "[/SAVE:${save_name}]") skip=false; continue ;;
    esac
    if [ "$skip" = false ]; then echo "$line" >> "$tmp_file"; fi
  done < "$BUILD_SAVE_FILE"
  mv "$tmp_file" "$BUILD_SAVE_FILE"
  echo "Deleted saved configuration: $save_name"
  return 0
}

# -----------------------------------------------------------------------------
# MAIN BUILD FUNCTION
# -----------------------------------------------------------------------------
do_build() {
  log_message "Starting build process..."
  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Build requires a git repository"
    exit 1
  fi

  # Determine build source commit
  if [ -z "$BUILD_SELECTED_COMMIT" ]; then
    BUILD_COMMIT="HEAD"
  else
    BUILD_COMMIT="$BUILD_SELECTED_COMMIT"
  fi

  # Determine build name
  if [ "$BUILD_STAGED" = true ]; then
    BUILD_COMMIT=""
    BUILD_COMMIT_MSG="Staged build - current working tree with uncommitted changes"
    if [ "$BUILD_MESSAGE_MODE" = true ]; then
      build_name="staged_$(date +%Y%m%d_%H%M%S)"
    else
      local ver=$(calculate_build_version "HEAD")
      if [ -n "$ver" ]; then
        build_name="${ver}-staged"
      else
        build_name="staged_$(date +%Y%m%d_%H%M%S)"
      fi
    fi
  else
    if [ "$BUILD_MESSAGE_MODE" = true ]; then
      BUILD_COMMIT_MSG=$(git log -1 --pretty=%B "$BUILD_COMMIT" 2>/dev/null | head -n1)
      build_name=$(sanitize_filename "$BUILD_COMMIT_MSG")
      [ -z "$build_name" ] && build_name="build_$(date +%Y%m%d_%H%M%S)"
    else
      local ver=$(calculate_build_version "$BUILD_COMMIT")
      if [ -n "$ver" ]; then
        build_name="$ver"
      else
        BUILD_COMMIT_MSG=$(git log -1 --pretty=%B "$BUILD_COMMIT" 2>/dev/null | head -n1)
        build_name=$(sanitize_filename "$BUILD_COMMIT_MSG")
        [ -z "$build_name" ] && build_name="build_$(date +%Y%m%d_%H%M%S)"
      fi
    fi
    BUILD_COMMIT_MSG=$(git log -1 --pretty=%B "$BUILD_COMMIT" 2>/dev/null | head -n1)
  fi

  # Handle --version
  if [ -n "$BUILD_VERSION" ]; then
    if [ "$BUILD_VERSION" = "latest" ]; then
      local tags=$(git tag --sort=-creatordate | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | head -1)
      if [ -n "$tags" ]; then
        BUILD_COMMIT=$(git rev-list -n 1 "$tags")
        BUILD_COMMIT_MSG="$tags"
      else
        local vcommit=$(git log --all --oneline --grep='^[0-9]\+\.[0-9]\+\(\.[0-9]\+\)\?$' --format="%H|%s" | head -1)
        if [ -n "$vcommit" ]; then
          BUILD_COMMIT=$(echo "$vcommit" | cut -d'|' -f1)
          BUILD_COMMIT_MSG=$(echo "$vcommit" | cut -d'|' -f2)
        else
          echo "No version found"; exit 1
        fi
      fi
    else
      if git rev-parse "$BUILD_VERSION" >/dev/null 2>&1; then
        BUILD_COMMIT=$(git rev-list -n 1 "$BUILD_VERSION")
        BUILD_COMMIT_MSG="$BUILD_VERSION"
      else
        BUILD_COMMIT=$(git log --all --oneline --grep="^${BUILD_VERSION}$" --format="%H" | head -1)
        [ -z "$BUILD_COMMIT" ] && BUILD_COMMIT=$(git log --all --oneline --grep="${BUILD_VERSION}" --format="%H" | head -1)
        if [ -n "$BUILD_COMMIT" ]; then
          BUILD_COMMIT_MSG="$BUILD_VERSION"
        else
          echo "Version '$BUILD_VERSION' not found"; exit 1
        fi
      fi
    fi
    if [ "$BUILD_MESSAGE_MODE" != true ]; then
      local ver=$(calculate_build_version "$BUILD_COMMIT")
      [ -n "$ver" ] && build_name="$ver"
    fi
  fi

  # Run config interface if requested
  if [ "$BUILD_CONFIG" = true ]; then
    build_config_interface
    if [ -n "$BUILD_SELECTED_COMMIT" ]; then
      BUILD_COMMIT="$BUILD_SELECTED_COMMIT"
      BUILD_COMMIT_MSG="$BUILD_SELECTED_COMMIT_MSG"
      if [ "$BUILD_MESSAGE_MODE" != true ]; then
        local ver=$(calculate_build_version "$BUILD_COMMIT")
        [ -n "$ver" ] && build_name="$ver"
      fi
    fi
  fi

  # Create temp build dir
  local temp_build="/tmp/raw_build_$$"
  rm -rf "$temp_build"; mkdir -p "$temp_build"

  log_message "Building: $build_name"
  log_message "Source: $([ -z "$BUILD_COMMIT" ] && echo "working tree" || echo "$BUILD_COMMIT_MSG")"

  # STEP 1: extract files
  if [ -z "$BUILD_COMMIT" ]; then
    log_message "Copying working tree (staged mode)..."
    (cd "$REPO_DIR" && find . -type f -not -path './.git/*' -exec sh -c 'mkdir -p "'$temp_build'/$(dirname "$1")"; cp "$1" "'$temp_build'/$1"' _ {} \; 2>/dev/null)
  else
    log_message "Extracting from git commit: $BUILD_COMMIT"
    git archive "$BUILD_COMMIT" | (cd "$temp_build" && tar xf -)
  fi

  # STEP 2: apply exclusions
  if [ -n "$EXCLUDE_DIRS_LIST" ] && [ -s "$EXCLUDE_DIRS_LIST" ]; then
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      if [ -e "$temp_build/$d" ]; then
        rm -rf "$temp_build/$d"
        log_message "Excluded dir: $d"
      fi
    done < "$EXCLUDE_DIRS_LIST"
  fi
  if [ -n "$EXCLUDE_LIST" ] && [ -s "$EXCLUDE_LIST" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if [ -e "$temp_build/$f" ]; then
        rm -rf "$temp_build/$f"
        log_message "Excluded file: $f"
      fi
    done < "$EXCLUDE_LIST"
  fi

  # STEP 3: apply inclusions from filesystem
  if [ -n "$BUILD_INCLUDE_LIST" ] && [ -s "$BUILD_INCLUDE_LIST" ]; then
    log_message "Applying filesystem inclusions..."
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local src="$REPO_DIR/$f"
      local dest="$temp_build/$f"
      if [ -f "$src" ]; then
        mkdir -p "$(dirname "$dest")"
        cp -p "$src" "$dest"
        log_message "  + included file: $f"
      elif [ -d "$src" ]; then
        mkdir -p "$dest"
        cp -rp "$src"/* "$dest"/ 2>/dev/null || true
        cp -rp "$src"/.[!.]* "$dest"/ 2>/dev/null || true
        log_message "  + included dir: $f"
      else
        log_message "  ! not found: $f"
      fi
    done < "$BUILD_INCLUDE_LIST"
  fi

  # STEP 4: clean empty dirs and count files
  find "$temp_build" -type d -empty -delete 2>/dev/null
  local file_count=$(find "$temp_build" -type f | wc -l)

  # STEP 5: create output
  mkdir -p "$BUILD_DIR"
  if [ "$BUILD_TAR" = true ]; then
    local tar_file="$BUILD_DIR/${build_name}.tar.gz"
    [ -f "$tar_file" ] && rm -f "$tar_file"
    mkdir -p "$temp_build/$build_name"
    for item in "$temp_build"/* "$temp_build"/.[!.]*; do
      [ -e "$item" ] || continue
      [ "$item" = "$temp_build/$build_name" ] && continue
      mv "$item" "$temp_build/$build_name/" 2>/dev/null
    done
    (cd "$temp_build" && tar -czf "$tar_file" "$build_name")
    echo ""
    echo "========================================="
    echo "  BUILD COMPLETE"
    echo "========================================="
    echo "  Archive: $tar_file"
    echo "  Size: $(ls -lh "$tar_file" | awk '{print $5}')"
    echo "  Files: $file_count"
    echo "  Source: $BUILD_COMMIT_MSG"
  else
    local out_dir="$BUILD_DIR/$build_name"
    [ -d "$out_dir" ] && rm -rf "$out_dir"
    mv "$temp_build" "$out_dir"
    echo ""
    echo "========================================="
    echo "  BUILD COMPLETE"
    echo "========================================="
    echo "  Directory: $out_dir"
    echo "  Size: $(du -sh "$out_dir" | awk '{print $1}')"
    echo "  Files: $file_count"
    echo "  Source: $BUILD_COMMIT_MSG"
  fi

  # Write info file
  local info_file="$BUILD_DIR/${build_name}.info"
  {
    echo "Build Name: $build_name"
    echo "Build Date: $(date)"
    echo "Source Commit: $(git rev-parse "$BUILD_COMMIT" 2>/dev/null || echo 'Staged')"
    echo "Commit Message: $BUILD_COMMIT_MSG"
    echo "Files: $file_count"
  } > "$info_file"

  rm -rf "$temp_build" 2>/dev/null
  log_message "Build process completed."
  exit 0
}

# -----------------------------------------------------------------------------
# HANDLE BUILD ARGUMENTS
# -----------------------------------------------------------------------------
handle_build_arguments() {
  local build_mode=false
  local arg

  for arg in "$@"; do
    case "$arg" in
      --build|--tar|--config|--message|--staged|--version)
        build_mode=true
        break
        ;;
    esac
  done

  if [ "$build_mode" = false ]; then
    return 1
  fi

  # Parse build flags
  local prev_arg=""
  for arg in "$@"; do
    case "$arg" in
      --build) BUILD_MODE=true ;;
      --tar) BUILD_TAR=true ;;
      --config) BUILD_CONFIG=true ;;
      --message) BUILD_MESSAGE_MODE=true ;;
      --staged) BUILD_STAGED=true ;;
      --version)
        BUILD_MODE=true
        BUILD_VERSION="latest"
        ;;
    esac

    # capture --build optional save name
    if [ "$prev_arg" = "--build" ] && [ "$arg" != "--build" ] && [ "$arg" != "--tar" ] && [ "$arg" != "--config" ] && [ "$arg" != "--message" ] && [ "$arg" != "--staged" ] && [ "$arg" != "--version" ] && [ "$arg" != "-log" ] && [ "$arg" != "-h" ] && [ "$arg" != "--help" ]; then
      BUILD_SAVE_NAME="$arg"
    fi

    # capture --version specific value
    if [ "$prev_arg" = "--version" ] && [ "$arg" != "--version" ] && echo "$arg" | grep -qE '^[0-9]+\.[0-9]+'; then
      BUILD_VERSION="$arg"
    fi

    prev_arg="$arg"
  done

  # If a save name is provided, load it
  if [ -n "$BUILD_SAVE_NAME" ]; then
    EXCLUDE_LIST="/tmp/build_exclude_$$.txt"
    EXCLUDE_DIRS_LIST="/tmp/build_exclude_dirs_$$.txt"
    : > "$EXCLUDE_LIST"; : > "$EXCLUDE_DIRS_LIST"; : > "$BUILD_INCLUDE_LIST"
    if load_build_configuration "$BUILD_SAVE_NAME"; then
      [ "$BUILD_TAR" = true ] && log_message "Command line --tar overrides saved setting"
      SAVED_INCLUDE_LIST="/tmp/build_include_saved_${BUILD_SAVE_NAME}.txt"
      [ -f "$SAVED_INCLUDE_LIST" ] && export SAVED_INCLUDE_LIST
    else
      echo "Failed to load save '$BUILD_SAVE_NAME'"
      exit 1
    fi
  else
    if [ "$BUILD_CONFIG" = false ]; then
      EXCLUDE_LIST="/tmp/build_exclude_$$.txt"
      EXCLUDE_DIRS_LIST="/tmp/build_exclude_dirs_$$.txt"
      : > "$EXCLUDE_LIST"; : > "$EXCLUDE_DIRS_LIST"; : > "$BUILD_INCLUDE_LIST"
    fi
  fi

  # Execute build
  do_build
  return 0
}

# =============================================================================
# END BUILD SYSTEM
# =============================================================================

# -----------------------------------------------------------------------------
# HELP MESSAGE
# -----------------------------------------------------------------------------
show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo "Install RawJS Runtime and BASM - JavaScript Runtime + Universal Runner"
  echo
  echo "Options:"
  echo "  -h, --help            Show this help"
  echo "  -log                  Enable installation logging"
  echo "  --with-git            Include .git directory in installation (default: exclude)"
  echo
  echo "BUILD OPTIONS (similar to EasyAI):"
  echo "  --build [name]        Create a build from the last commit (optional: saved configuration name)"
  echo "  --tar                 Create a tar.gz archive (use with --build)"
  echo "  --config              Interactive file exclusion (use with --build)"
  echo "  --message             Use commit message for build naming"
  echo "  --staged              Build from current working tree including uncommitted changes"
  echo "  --version [VER]       Build from a specific version or 'latest' (use with --build)"
  echo
  echo "This will install:"
  echo "  • RawJS runtime to $INSTALL_DIR"
  echo "  • BASM tools to $INSTALL_DIR/._basm"
  echo "  • Global 'raw' command"
  echo "  • Global 'basm' command"
  echo
  echo "RAWJS COMMAND:"
  echo "  • Run from the caller's current directory"
  echo "  • Execute Raw.sh with provided arguments"
  echo
  echo "BASM COMMAND:"
  echo "  • Run from the caller's current directory"
  echo "  • Execute basm.sh with provided arguments"
  echo
  echo "BUILD EXAMPLES:"
  echo "  $0 --build                  Create build directory from HEAD"
  echo "  $0 --build --tar            Create tar.gz archive"
  echo "  $0 --build --config         Interactive exclusion before build"
  echo "  $0 --build --staged         Build from working tree"
  echo "  $0 --build myconfig         Build using saved configuration 'myconfig'"
  echo
  exit 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

trap interrupt_handler INT TERM

# -----------------------------------------------------------------------------
# EARLY CHECK FOR BUILD MODE
# -----------------------------------------------------------------------------
if handle_build_arguments "$@"; then
  exit 0
fi

# Original argument parsing
PROVIDED_JS_FILE=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help ;;
    -log) LOG_MODE=true; touch "$LOG_FILE" ;;
    --with-git) INCLUDE_GIT=true ;;
    *)
      # Check if this argument is a .js file (not a flag)
      case "$arg" in
        -*) ;; # skip flags
        *)
          case "$arg" in
            *.js) PROVIDED_JS_FILE="$arg" ;;
          esac
          ;;
      esac
      ;;
  esac
done

log_message "Starting RawJS and BASM installation..."

# Alpine NASM replacement
SYSTEM_TYPE=$(detect_system)
handle_alpine_nasm_replacement "$SYSTEM_TYPE"

# Verify source files
if [ ! -f "$RAWJS_SOURCE_DIR/Raw.sh" ]; then
  echo "Error: Raw.sh not found at: $RAWJS_SOURCE_DIR/Raw.sh" >&2
  exit 1
fi

INSTALL_BASM=true
if [ ! -d "$BASM_SOURCE_DIR" ]; then
  echo "Warning: BASM directory not found at: $BASM_SOURCE_DIR" >&2
  echo "BASM will not be installed."
  INSTALL_BASM=false
fi

# Handle existing installation
IS_FIRST_INSTALL=false
if [ -d "$INSTALL_DIR" ]; then
  log_message "Existing installation found."
  if [ -n "$PROVIDED_JS_FILE" ]; then
    log_message "JS file provided - forcing update..."
    remove_installation
    IS_FIRST_INSTALL=true
  else
    echo "Choose an option:"
    echo "  1 = Update"
    echo "  2 = Remove"
    echo "  3 = Exit"
    printf "Enter your choice [1-3]: "
    read choice
    case "$choice" in
      1) remove_installation; IS_FIRST_INSTALL=true ;;
      2) remove_installation; echo "Uninstalled."; exit 0 ;;
      3) echo "Exiting."; exit 0 ;;
      *) echo "Invalid choice."; exit 1 ;;
    esac
  fi
else
  IS_FIRST_INSTALL=true
fi

# Install packages on first install if BASM present
if [ "$IS_FIRST_INSTALL" = true ] && [ "$INSTALL_BASM" = true ]; then
  install_system_packages "$SYSTEM_TYPE"
fi

# Create installation directory
log_message "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy RawJS files
if ! copy_files "$RAWJS_SOURCE_DIR" "$INSTALL_DIR" "RawJS"; then
  echo "Error: RawJS copy failed"
  exit 1
fi

# Verify RawJS
if ! verify_rawjs_structure "$INSTALL_DIR"; then
  echo "Error: RawJS verification failed"
  exit 1
fi

# Copy BASM files
if [ "$INSTALL_BASM" = true ]; then
  log_message "Installing BASM tools..."
  mkdir -p "$INSTALL_DIR/._basm"
  if ! copy_files "$BASM_SOURCE_DIR" "$INSTALL_DIR/._basm" "BASM"; then
    echo "Error: BASM copy failed"
    exit 1
  fi
  if ! verify_basm_structure "$INSTALL_DIR"; then
    echo "Warning: BASM verification failed"
  fi
fi

# Restore config files after installation
restore_config_files

# Create wrappers
create_raw_wrapper "$INSTALL_DIR"
if [ "$INSTALL_BASM" = true ]; then create_basm_wrapper "$INSTALL_DIR"; fi

cleanup

# Initialize RawJS
log_message "Initializing RawJS environment..."

echo
echo "Warming up RawJS base pool..."
if [ -f "$BIN_DIR/raw" ] && [ -x "$BIN_DIR/raw" ]; then
  if raw --start; then
    log_message "✓ RawJS base pool warmed successfully"
  else
    log_message "⚠ RawJS base pool warm-up had issues"
  fi
else
  log_message "⚠ raw command not found, cannot warm base pool"
fi

echo
echo "Running 'raw --reset' to build initial directory structure..."
if [ -f "$BIN_DIR/raw" ] && [ -x "$BIN_DIR/raw" ]; then
  if raw --reset; then
    log_message "✓ RawJS environment initialized successfully"
  else
    log_message "⚠ RawJS initialization had issues"
    echo "You can manually run: raw --reset"
  fi
else
  log_message "⚠ raw command not found, cannot run --reset"
fi

echo
log_message "RawJS and BASM installation completed!"

# Final message or execute provided JS
if [ -n "$PROVIDED_JS_FILE" ]; then
  echo "=========================================="
  echo "Executing provided JavaScript file: $PROVIDED_JS_FILE"
  echo "=========================================="
  if [ -f "$BIN_DIR/raw" ]; then
    raw "$PROVIDED_JS_FILE"
    exit $?
  else
    echo "Error: raw command not found" >&2
    exit 1
  fi
else
  echo
  echo "=========================================="
  echo "RAWJS & BASM INSTALLATION SUCCESSFUL"
  echo "=========================================="
  echo
  echo "Usage: bash Raw.sh [--log] <path/to/file.js> [args...]"
  echo "       bash Raw.sh --reset"
  echo "       bash Raw.sh --test"
  echo "       bash Raw.sh --tool [command] [args...]"
  echo "       bash Raw.sh --<tool> [args...]"
  echo "       bash Raw.sh --tools"
  echo "       bash Raw.sh --version"
  echo "       bash Raw.sh --dev"
  echo "       bash Raw.sh --asm [path/to/file.js] [args...]"
  echo
  if [ "$INSTALL_BASM" = true ]; then
    echo "Available commands:"
    echo "  raw              RawJS JavaScript Runtime"
    echo "  basm             BASM Universal Runner"
    echo
  fi
  echo "Installation directory: $INSTALL_DIR"
  echo "Command symlinks:"
  echo "  • $BIN_DIR/raw"
  if [ "$INSTALL_BASM" = true ]; then echo "  • $BIN_DIR/basm"; fi
  echo
  echo "To uninstall, run this script again and choose option 2."
  echo "=========================================="
fi