#!/usr/bin/env bash
# one-armed-remnux-fixup.sh
# Post-install fixes for REMnux on Ubuntu 24 ARM64 (aarch64)
# Companion to ../README.md
set -euo pipefail

FAILURES=0
SKIPS=0

fail() {
  echo "  FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

skip() {
  echo "  SKIP: $*"
  SKIPS=$((SKIPS + 1))
}

finish() {
  local status=$1
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    # Also covers an unexpected unguarded command failure under set -e.
    if [ "$FAILURES" -eq 0 ]; then
      fail "script stopped early (exit ${status}); review the preceding output."
    else
      echo "Script stopped early (exit ${status}); review the preceding failure."
    fi
  elif [ "$FAILURES" -gt 0 ]; then
    status=1
  fi
  echo ""
  echo "Summary: ${FAILURES} reported failure(s), ${SKIPS} skipped action(s); exit ${status}."
  if [ "$SKIPS" -gt 0 ]; then
    echo "Skipped actions need review; exit 0 does not mean every tool was installed or tested."
  fi
  exit "$status"
}
trap 'finish "$?"' EXIT

# Release baseline; see README for revision-specific VM validation status.
TESTED_SALT_STATES_VERSION="v2026.41.2"
SALT_STATES_CACHE_DIR="/var/cache/cast/remnux_salt-states"

echo "======================================"
echo " REMnux ARM64 Post-Install Fix Script"
echo "======================================"
echo ""

echo "Compatibility baseline: REMnux salt-states ${TESTED_SALT_STATES_VERSION}"

LATEST_SALT_STATES_DIR=""
shopt -s nullglob
SALT_STATES_DIRS=("${SALT_STATES_CACHE_DIR}"/v*)
shopt -u nullglob

for salt_states_dir in "${SALT_STATES_DIRS[@]}"; do
  if [ -d "${salt_states_dir}" ] \
    && { [ -z "${LATEST_SALT_STATES_DIR}" ] || [ "${salt_states_dir}" -nt "${LATEST_SALT_STATES_DIR}" ]; }; then
    LATEST_SALT_STATES_DIR="${salt_states_dir}"
  fi
done

if [ -z "${LATEST_SALT_STATES_DIR}" ]; then
  echo "  WARN: could not detect a salt-states release under ${SALT_STATES_CACHE_DIR}"
else
  DETECTED_SALT_STATES_VERSION="${LATEST_SALT_STATES_DIR##*/}"
  if [ "${DETECTED_SALT_STATES_VERSION}" = "${TESTED_SALT_STATES_VERSION}" ]; then
    echo "  OK: detected tested salt-states release ${DETECTED_SALT_STATES_VERSION}"
  else
    echo "  WARN: detected salt-states ${DETECTED_SALT_STATES_VERSION}, but this script was last tested with ${TESTED_SALT_STATES_VERSION}"
    echo "        Continuing with guarded checks. Review all OK/FAIL/SKIP lines."
  fi
fi

echo ""

echo "[1/11] Handling the i386 foreign architecture..."
# Once the Ubuntu base-source validation passes, leaving i386 registered is safe.
# Remove it only when no i386 package records use it, since Wine may install them.
if dpkg --print-foreign-architectures | grep -q i386; then
  mapfile -t I386_PACKAGE_RECORDS < <(
    dpkg-query -W -f='${binary:Package}\t${Architecture}\t${db:Status-Abbrev}\n' 2>/dev/null \
      | awk '$2 == "i386" && $3 != "un" {print $1 " [" $3 "]"}'
  )

  if [ "${#I386_PACKAGE_RECORDS[@]}" -gt 0 ]; then
    skip "i386 is used by ${#I386_PACKAGE_RECORDS[@]} package record(s), leaving it registered"
    printf '    %s\n' "${I386_PACKAGE_RECORDS[@]:0:8}"
    if [ "${#I386_PACKAGE_RECORDS[@]}" -gt 8 ]; then
      echo "    ... and $((${#I386_PACKAGE_RECORDS[@]} - 8)) more"
    fi
  elif sudo dpkg --remove-architecture i386; then
    echo "  OK: unused i386 architecture removed"
  else
    skip "i386 could not be removed, leaving it registered"
  fi
else
  echo "  OK: i386 not registered, nothing to do"
fi

echo ""
echo "[2/11] Validating sources and fixing dpkg/apt state..."
if ! sudo apt update; then
  fail "apt update failed; stopping before using potentially stale indexes."
  echo "  Check the errors above for network/signature problems or unsupported architectures."
  echo "  For Ports i386 errors, restrict every Ubuntu base stanza to arm64 (guide Step 2.1)."
  echo "  Do not force-remove installed i386 packages; repair the sources, then rerun."
  exit 1
fi

if ! APT_INDEX_TARGETS="$(apt-get indextargets \
  --format '$(SITE) $(RELEASE) $(ARCHITECTURE) $(COMPONENT)' 'Identifier: Packages')"; then
  fail "could not inspect active APT package indexes"
  exit 1
fi
if ! AMD64_LIBC_POLICY="$(apt-cache policy libc6:amd64 2>/dev/null)"; then
  fail "could not inspect libc6:amd64 policy"
  exit 1
fi
AMD64_LIBC_CANDIDATE="$(printf '%s\n' "${AMD64_LIBC_POLICY}" \
  | awk '/Candidate:/ {print $2; exit}')"

if printf '%s\n' "${APT_INDEX_TARGETS}" | grep -q 'archive\.ubuntu\.com/ubuntu'; then
  fail "active Ubuntu indexes from archive.ubuntu.com detected on ARM64"
  echo "  Fix ubuntu.sources as described in guide Step 2.1, then rerun this script."
  exit 1
fi

if [ -n "${AMD64_LIBC_CANDIDATE}" ] && [ "${AMD64_LIBC_CANDIDATE}" != "(none)" ]; then
  fail "libc6:amd64 candidate ${AMD64_LIBC_CANDIDATE} is visible to apt"
  echo "  Fix ubuntu.sources as described in guide Step 2.1, then rerun this script."
  exit 1
fi

echo "  OK: no Ubuntu amd64 base indexes or libc6:amd64 candidate detected"
if ! sudo dpkg --configure -a; then
  echo "  WARN: dpkg configuration failed; attempting APT dependency repair next."
fi
if ! sudo apt --fix-broken install -y; then
  fail "APT dependency repair failed; resolve the package errors before rerunning."
  exit 1
fi
if ! sudo dpkg --configure -a; then
  fail "dpkg configuration still fails after APT repair; stopping."
  exit 1
fi
echo "  OK: dpkg/apt state checked"

echo ""
echo "[3/11] Installing build dependencies + replacements..."
# Required by later download/build steps: failure must stop the script.
required_apt_packages=(curl unzip cmake build-essential python3-dev python3-venv openjdk-21-jdk)
missing_required_apt=()
for pkg in "${required_apt_packages[@]}"; do
  if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
    missing_required_apt+=("${pkg}")
  fi
done

if [ "${#missing_required_apt[@]}" -gt 0 ]; then
  echo "  Installing missing required apt packages: ${missing_required_apt[*]}"
  if sudo apt install -y "${missing_required_apt[@]}"; then
    echo "  OK: required build/download dependencies installed"
  else
    fail "required apt packages could not be installed: ${missing_required_apt[*]}"
    echo "  Stopping: later builds depend on these prerequisites. Fix APT, then rerun."
    exit 1
  fi
else
  echo "  OK: required build/download dependencies already installed"
fi

# Replacements are independent of the later builds. Try each missing package
# separately so one unavailable replacement does not block another one.
replacement_apt_packages=(7zip p7zip-full)
for pkg in "${replacement_apt_packages[@]}"; do
  if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
    echo "  OK: apt replacement already installed: ${pkg}"
  elif sudo apt install -y "${pkg}"; then
    echo "  OK: apt replacement installed: ${pkg}"
  else
    fail "apt replacement could not be installed: ${pkg}"
    echo "  Continuing with independent tools; the final exit status will be nonzero."
  fi
done

# Ubuntu's non-free unrar may require multiverse. If unavailable, use unrar-free
# as the safe baseline and install unrar later only when better RAR support is needed.
if dpkg-query -W -f='${Status}' unrar 2>/dev/null | grep -q "install ok installed"; then
  echo "  OK: unrar already installed"
elif dpkg-query -W -f='${Status}' unrar-free 2>/dev/null | grep -q "install ok installed"; then
  echo "  OK: unrar-free already installed"
else
  echo "  Installing unrar (may require Ubuntu multiverse)..."
  if sudo apt install -y unrar; then
    echo "  OK: unrar installed"
  elif sudo apt install -y unrar-free; then
    echo "  OK: unrar-free installed as baseline fallback"
  else
    skip "neither unrar nor unrar-free could be installed"
  fi
fi

echo ""
echo "[4/11] Checking nodejs + npm tools..."
# In the contaminated-source test run, the nodejs pkg state died from a broken
# apt refresh and cascaded to the npm tools. Only install what is missing.
npm_packages=(box-js webcrack js-deobfuscator opencode-ai @remnux/mcp-server)
npm_tooling_complete=false
JSTILLERY_CLI=""

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  JSTILLERY_CLI="$(npm root -g 2>/dev/null || true)/JStillery_Server/jstillery_cli.js"
  missing_npm=()
  for pkg in "${npm_packages[@]}"; do
    if ! npm list -g --depth=0 "${pkg}" >/dev/null 2>&1; then
      missing_npm+=("${pkg}")
    fi
  done
  if [ "${#missing_npm[@]}" -eq 0 ] && [ -x "${JSTILLERY_CLI}" ]; then
    sudo ln -sf "${JSTILLERY_CLI}" /usr/local/bin/jstillery
    echo "  OK: nodejs + npm tooling already installed, skipping"
    npm_tooling_complete=true
  fi
fi

if [ "${npm_tooling_complete}" != true ] && sudo apt install -y nodejs; then
  if ! command -v npm >/dev/null 2>&1; then
    fail "npm not found after installing nodejs"
  else
    missing_npm=()
    for pkg in "${npm_packages[@]}"; do
      if ! npm list -g --depth=0 "${pkg}" >/dev/null 2>&1; then
        missing_npm+=("${pkg}")
      fi
    done

    if [ "${#missing_npm[@]}" -gt 0 ]; then
      echo "  Installing missing npm packages: ${missing_npm[*]}"
      sudo npm install -g "${missing_npm[@]}" || \
        fail "some npm packages failed, retry them individually"
    else
      echo "  OK: core npm tooling already installed"
    fi

    JSTILLERY_CLI="$(npm root -g 2>/dev/null || true)/JStillery_Server/jstillery_cli.js"
    if [ -x "${JSTILLERY_CLI}" ]; then
      sudo ln -sf "${JSTILLERY_CLI}" /usr/local/bin/jstillery
      echo "  OK: JStillery already installed"
    else
      echo "  Installing JStillery from git..."
      if sudo npm install -g git+https://github.com/mindedsecurity/JStillery.git; then
        JSTILLERY_CLI="$(npm root -g 2>/dev/null || true)/JStillery_Server/jstillery_cli.js"
        if [ -x "${JSTILLERY_CLI}" ]; then
          sudo ln -sf "${JSTILLERY_CLI}" /usr/local/bin/jstillery
          echo "  OK: JStillery installed and command linked"
        else
          fail "JStillery installed, but jstillery_cli.js is missing or not executable"
        fi
      else
        fail "JStillery install failed"
      fi
    fi
    echo "  Node.js/npm checks completed; see individual results above."
  fi
elif [ "${npm_tooling_complete}" != true ]; then
  fail "nodejs install failed, check the NodeSource repo configuration"
fi

echo ""
echo "[5/11] Installing Ghidra from upstream..."
# Pinned release, Ubuntu ARM64 build and GUI smoke-tested 2026-10-05.
GHIDRA_ZIP="${GHIDRA_ZIP:-ghidra_12.1.4_PUBLIC_20260921.zip}"
GHIDRA_TAG="${GHIDRA_TAG:-Ghidra_12.1.4_build}"
GHIDRA_URL="${GHIDRA_URL:-https://github.com/NationalSecurityAgency/ghidra/releases/download/${GHIDRA_TAG}/${GHIDRA_ZIP}}"
GHIDRA_DIR=""
if [ ! -d /opt/ghidra ] && [ ! -L /opt/ghidra ]; then
  GHIDRA_DOWNLOAD_DIR=$(mktemp -d)
  GHIDRA_ARCHIVE="${GHIDRA_DOWNLOAD_DIR}/ghidra.zip"
  echo "  Downloading Ghidra..."
  if curl -fsSL "${GHIDRA_URL}" -o "${GHIDRA_ARCHIVE}"; then
    mapfile -t GHIDRA_ARCHIVE_ROOTS < <(
      unzip -Z1 "${GHIDRA_ARCHIVE}" 2>/dev/null \
        | awk -F/ 'NF > 1 && $1 != "" {print $1}' \
        | sort -u
    )

    if [ "${#GHIDRA_ARCHIVE_ROOTS[@]}" -ne 1 ] \
      || [ "${GHIDRA_ARCHIVE_ROOTS[0]:-}" = "." ] \
      || [ "${GHIDRA_ARCHIVE_ROOTS[0]:-}" = ".." ]; then
      fail "expected exactly one top-level directory in ${GHIDRA_ZIP}"
    else
      GHIDRA_DIR="/opt/${GHIDRA_ARCHIVE_ROOTS[0]}"
      echo "  Extracting ${GHIDRA_ARCHIVE_ROOTS[0]}..."
      if ! sudo unzip -q -o "${GHIDRA_ARCHIVE}" -d /opt/; then
        fail "Ghidra extraction failed; check disk space, permissions and the archive"
      elif [ -d "${GHIDRA_DIR}" ]; then
        sudo ln -sf "${GHIDRA_DIR}" /opt/ghidra
        sudo ln -sf "${GHIDRA_DIR}/ghidraRun" /usr/local/bin/ghidra
        echo "  OK: Ghidra installed at ${GHIDRA_DIR}"
      else
        fail "archive root was not extracted as expected: ${GHIDRA_DIR}"
      fi
    fi
  else
    fail "Ghidra download failed, check the release URL and retry manually"
  fi
  rm -f -- "${GHIDRA_ARCHIVE}"
  rmdir -- "${GHIDRA_DOWNLOAD_DIR}"
else
  echo "  OK: /opt/ghidra already exists, skipping download"
fi

echo ""
echo "[6/11] Building Ghidra native components for linux_arm_64..."
GHIDRA_DIR=$(readlink -f /opt/ghidra 2>/dev/null || echo "")

if [ -n "${GHIDRA_DIR}" ] && [ -d "${GHIDRA_DIR}" ]; then
  # Idempotency: skip if the arm64 decompiler was already built
  DECOMPILER_NATIVE=$(find "${GHIDRA_DIR}" -path '*/os/linux_arm_64/decompile' -type f 2>/dev/null | head -1)
  if [ -n "${DECOMPILER_NATIVE}" ]; then
    echo "  OK: linux_arm_64 natives already built, skipping"
  else
    GRADLE_DIR="${GHIDRA_DIR}/support/gradle"
    if [ -d "${GRADLE_DIR}" ]; then
      echo "  Building native binaries (decompiler, sleigh, etc.)..."
      echo "  Takes about a minute. The Gradle wrapper needs internet on first run..."
      # The release ZIP does not mark gradlew executable, so set it defensively.
      sudo chmod +x "${GRADLE_DIR}/gradlew"
      if (cd "${GRADLE_DIR}" && sudo ./gradlew buildNatives); then
        echo "  OK: Ghidra native components built for linux_arm_64"
      else
        fail "buildNatives failed, check build-essential and the JDK"
        echo "    Retry manually: cd ${GRADLE_DIR} && sudo ./gradlew buildNatives"
      fi
    else
      fail "${GRADLE_DIR} not found, unexpected Ghidra layout"
      echo "    Check: ls ${GHIDRA_DIR}/support/"
    fi
  fi
else
  skip "Ghidra installation not found, skipping"
fi

echo ""
echo "[7/11] Installing PowerShell from tarball..."
if ! command -v pwsh &>/dev/null; then
  PWSH_VER="${PWSH_VER:-7.6.6}"  # pinned release, Ubuntu ARM64 smoke-tested 2026-10-05
  if [ "${PWSH_VER}" = "latest" ]; then
    if ! PWSH_VER="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"; then
      fail "could not resolve latest PowerShell version"
      PWSH_VER=""
    fi
  fi
  if [ -n "${PWSH_VER}" ]; then
    echo "  Downloading PowerShell ${PWSH_VER} for ARM64..."
    if curl -fsSL -o /tmp/powershell.tar.gz \
      "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/powershell-${PWSH_VER}-linux-arm64.tar.gz" && \
      sudo mkdir -p /opt/microsoft/powershell/7 && \
      sudo tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 && \
      sudo chmod +x /opt/microsoft/powershell/7/pwsh && \
      sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh; then
      rm -f /tmp/powershell.tar.gz
      echo "  OK: PowerShell $(pwsh --version) installed"
    else
      rm -f /tmp/powershell.tar.gz
      fail "PowerShell install failed, check the network and release URL"
    fi
  fi
else
  echo "  OK: pwsh already available ($(pwsh --version))"
fi

echo ""
echo "[8/11] Checking qiling + keystone-engine..."
QILING_PYTHON="/opt/qiling/bin/python"
QILING_SMOKE_TEST='from keystone import Ks, KS_ARCH_X86, KS_MODE_32; from qiling import Qiling; assert Ks(KS_ARCH_X86, KS_MODE_32).asm("nop")[0] == [0x90]'

if [ -x "${QILING_PYTHON}" ]; then
  if "${QILING_PYTHON}" -c "${QILING_SMOKE_TEST}" >/dev/null 2>&1; then
    sudo ln -sf /opt/qiling/bin/qltool /usr/local/bin/qltool
    echo "  OK: qiling + keystone-engine already installed and functional"
  else
    QILING_PIP_VERSION="$("${QILING_PYTHON}" -m pip --version 2>/dev/null | awk 'NR == 1 {print $2}')"
    QILING_BUILD_ARGS=()

    if "${QILING_PYTHON}" -m pip install \
      --use-feature=venv-isolation --help >/dev/null 2>&1; then
      QILING_BUILD_ARGS=(--use-feature=venv-isolation)
      echo "  Building keystone-engine with pip ${QILING_PIP_VERSION} standard-venv isolation..."
    else
      echo "  pip ${QILING_PIP_VERSION:-unknown} does not expose venv-isolation, using default isolation..."
    fi

    if sudo "${QILING_PYTHON}" -m pip install --quiet \
      "${QILING_BUILD_ARGS[@]}" 'keystone-engine==0.9.2'; then
      if sudo "${QILING_PYTHON}" -m pip install --quiet \
        "${QILING_BUILD_ARGS[@]}" qiling && \
        sudo "${QILING_PYTHON}" -c "${QILING_SMOKE_TEST}"; then
        sudo ln -sf /opt/qiling/bin/qltool /usr/local/bin/qltool
        echo "  OK: qiling + keystone-engine installed and functional"
      else
        fail "qiling install or smoke test failed"
      fi
    else
      fail "keystone-engine ARM64 build failed"
    fi
  fi
else
  skip "/opt/qiling venv not found, skipping"
fi

echo ""
echo "[9/11] Checking flare-floss..."
FLOSS_VER="${FLOSS_VER:-3.1.1}"
FLOSS_VENV="/opt/floss"
FLOSS_UPSTREAM_VENV="/opt/flare-floss"

# Newer REMnux releases own this environment and its command links.
# Do not mask an upstream failure by switching back to the legacy fixup venv.
if [ -e "${FLOSS_UPSTREAM_VENV}" ] || [ -L "${FLOSS_UPSTREAM_VENV}" ]; then
  if [ -x "${FLOSS_UPSTREAM_VENV}/bin/python" ] && \
    [ -x "${FLOSS_UPSTREAM_VENV}/bin/floss" ] && \
    "${FLOSS_UPSTREAM_VENV}/bin/python" -c \
      'import binary2strings as b; assert b.extract_all_strings(b"FLARE_FLOSS_ARM64_SMOKE_TEST")' \
      >/dev/null 2>&1 && \
    "${FLOSS_UPSTREAM_VENV}/bin/floss" -h >/dev/null 2>&1; then
    if [ "$(readlink -f /usr/local/bin/floss 2>/dev/null)" = \
      "$(readlink -f "${FLOSS_UPSTREAM_VENV}/bin/floss")" ]; then
      echo "  OK: upstream flare-floss already installed and functional, leaving it unchanged"
    else
      fail "upstream flare-floss command link is missing or points elsewhere"
      echo "  Check /usr/local/bin/floss and the REMnux FLOSS state. No FLOSS files or links were changed."
    fi
  else
    fail "upstream flare-floss failed its smoke check"
    echo "  Check ${FLOSS_UPSTREAM_VENV} and the REMnux installer logs. No FLOSS files or links were changed."
  fi
elif [ -x "${FLOSS_VENV}/bin/floss" ] && \
  "${FLOSS_VENV}/bin/python" -c \
    'import binary2strings as b; assert b.extract_all_strings(b"FLARE_FLOSS_ARM64_SMOKE_TEST")' \
    >/dev/null 2>&1 && \
  "${FLOSS_VENV}/bin/floss" -h >/dev/null 2>&1; then
  sudo ln -sf "${FLOSS_VENV}/bin/floss" /usr/local/bin/floss
  echo "  OK: flare-floss already installed and functional"
else
  echo "  Installing flare-floss ${FLOSS_VER}. binary2strings will build for ARM64..."
  if sudo python3 -m venv "${FLOSS_VENV}" && \
    sudo "${FLOSS_VENV}/bin/python" -m pip install --quiet --upgrade pip setuptools wheel && \
    sudo "${FLOSS_VENV}/bin/python" -m pip install --quiet "flare-floss==${FLOSS_VER}"; then
    if sudo "${FLOSS_VENV}/bin/python" -c \
      'import binary2strings as b; assert b.extract_all_strings(b"FLARE_FLOSS_ARM64_SMOKE_TEST")' && \
      sudo "${FLOSS_VENV}/bin/floss" -h >/dev/null 2>&1; then
      sudo ln -sf "${FLOSS_VENV}/bin/floss" /usr/local/bin/floss
      echo "  OK: flare-floss ${FLOSS_VER} installed and functional"
    else
      fail "flare-floss installed, but the ARM64 smoke test failed"
    fi
  else
    fail "flare-floss install failed, check the compiler and pip output"
  fi
fi

echo ""
echo "[10/11] Fixing vivisect (without PyQt5 GUI)..."
if [ -d /opt/vivisect ]; then
  if /opt/vivisect/bin/pip show vivisect >/dev/null 2>&1; then
    sudo ln -sf /opt/vivisect/bin/vivbin /usr/local/bin/vivbin
    sudo ln -sf /opt/vivisect/bin/vdbbin /usr/local/bin/vdbbin
    echo "  OK: vivisect already installed (CLI only, no GUI)"
  elif sudo /opt/vivisect/bin/pip install --quiet vivisect; then
    sudo ln -sf /opt/vivisect/bin/vivbin /usr/local/bin/vivbin
    sudo ln -sf /opt/vivisect/bin/vdbbin /usr/local/bin/vdbbin
    echo "  OK: vivisect installed (CLI only, no GUI)"
  else
    fail "vivisect install failed"
  fi
else
  skip "/opt/vivisect venv not found, skipping"
fi

echo ""
echo "[11/11] Exposing the Magika Python client on ARM64..."
MAGIKA_PYTHON_CLIENT="/opt/magika/bin/magika-python-client"

if [ -x "${MAGIKA_PYTHON_CLIENT}" ]; then
  if "${MAGIKA_PYTHON_CLIENT}" --version >/dev/null 2>&1; then
    sudo ln -sf "${MAGIKA_PYTHON_CLIENT}" /usr/local/bin/magika-python-client
    echo "  OK: magika-python-client linked and functional"
  else
    fail "installed magika-python-client failed its version check"
  fi
else
  skip "${MAGIKA_PYTHON_CLIENT} not found"
fi

echo ""
echo "=========================================="
echo " Done"
echo "=========================================="
echo ""
echo "Review the OK/FAIL/SKIP lines above for actual results."
echo ""
echo "Optional manual fix (see guide, section 4.11):"
echo "  * peframe-ds via pip --no-deps (works, but bypasses dep resolution)"
echo ""
echo "Not provided by this native ARM64 fix path (see guide, step 5):"
echo "  * x86 Wine workflows (shellcode2exe.bat, ssview): states may skip/pass without working tools"
echo "  * STPyV8 -> thug, peepdf-3"
echo "  * PyQt5 -> pe-tree, vivisect GUI"
echo "  * i386 multilib -> js-patched (use js115 instead)"
echo "  * REMnux PPA x86 binaries: scdbg, binee, edb-debugger, ..."
echo ""
echo "Quick source builds if needed (see guide, step 5):"
echo "  * xorsearch/xorstrings: portable C, gcc -o xorsearch XORSearch.c"
