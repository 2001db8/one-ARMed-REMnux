<p align="center">
  <img src="images/oar_logo_light.png" alt="one-ARMed-REMnux logo" width="320">
</p>

REMnux's [official installation guide](https://docs.remnux.org/install-distro/install-from-scratch) still targets x86_64, but salt-states v2026.41.2 finally include partial ARM64 support. "One ARMed REMnux" covers the remaining fixes for an Ubuntu 24.04 ARM64 (aarch64) guest VM on VMware Fusion.

Official ARM support is on the roadmap, as REMnux maintainer Lenny Zeltser confirmed in [salt-states issue #241](https://github.com/REMnux/salt-states/issues/241#issuecomment-1562141207). The upstream [ARM64 changes](https://github.com/REMnux/salt-states/commit/9d51a0bb50817d86cdfda929fac9fddef105b67b) and [FLOSS/Qiling fixes](https://github.com/REMnux/salt-states/commit/b27b3cb251294a8fcdc3b8eb2546865100fd861b) address several earlier installation problems. They do not yet make every tool available on ARM64.

This guide covers preparation, installation, fixes and alternatives for tools that do not work natively. Results depend on the [salt-states release](https://github.com/REMnux/salt-states/releases) and how you prepare the VM.

You need internet access during installation and updates. After that, analysis can run offline. This is a community guide, and corrections and pull requests are welcome.

> [!IMPORTANT]
> **Last tested version**
>
> REMnux salt-states **v2026.41.2** on **Ubuntu 24.04.5 ARM64**, tested on **2026-10-07**.
>
> Fresh installation and upgrade from **v2026.37.1** were tested in dedicated mode. See the [test results](docs/TEST-RESULTS.md) for coverage, known limits and release history.

## Contents

- [Step 1 - VM Setup](#step-1---vm-setup)
- [Step 2 - Pre-Install Preparation](#step-2---pre-install-preparation) (ARM64-only Ubuntu sources, build dependencies)
- [Step 3 - Run the REMnux Installer](#step-3---run-the-remnux-installer)
- [Step 4 - Post-Install Fixes](#step-4---post-install-fixes) (apt cleanup, nodejs, Ghidra, PowerShell, qiling, vivisect, FLOSS, Magika, peframe)
- [Step 5 - Not Worth Fixing](#step-5---probably-not-worth-fixing-imho-and-what-to-use-instead)
- [Sample Handling (In/Egress)](#sample-handling-inegress)
- [Fallback: amd64 REMnux via emulation](#fallback-amd64-remnux-via-emulation)
- [Test results](docs/TEST-RESULTS.md)

## Step 1 - VM Setup

1. Create the VM in VMware Fusion: Ubuntu 24.04 ARM64, recommend ≥4 vCPU, ≥8 GB RAM, ≥60 GB disk (the full REMnux install is large, plus samples and build artifacts).
2. Install Ubuntu 24.04 ARM64 (Desktop or Server + your preferred DE). See <https://docs.remnux.org/install-distro/install-from-scratch#install-ubuntu>
3. Update Ubuntu before installing REMnux and install the VMware guest tools.

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y open-vm-tools open-vm-tools-desktop
```

4. **Take a VM snapshot now.** The REMnux installer runs for a good while and changes the system heavily, so a clean pre-install snapshot is your cheapest way back.

## Step 2 - Pre-Install Preparation

### 2.1 Back up and restrict the Ubuntu base sources to ARM64

On ARM64, the Ubuntu base packages have to come from `ports.ubuntu.com/ubuntu-ports` as `arm64`. A mixed Deb822 configuration file can contain one correct ARM64 stanza plus a second `archive.ubuntu.com` stanza carrying `Architectures: amd64 i386`. When that happens, apt starts offering ordinary amd64 packages such as `aeskeyfind`, `rar`, and `edb-debugger`, which dpkg then rejects on the ARM64 system. So a simple grep for any `Architectures: arm64` line is not enough on its own.

Older REMnux releases registered i386 for Wine. v2026.41.2 skips that step on ARM64, but an upgraded VM can retain the registration. Without an explicit `Architectures:` field, APT uses all configured architectures for that source. Keep the Ubuntu base sources restricted to ARM64 so that an existing or later i386 registration cannot trigger requests against Ubuntu Ports. See [Ubuntu's sources.list documentation](https://manpages.ubuntu.com/manpages/noble/man5/sources.list.5.html).

> [!WARNING]
> This applies to **fresh installations too**. Restrict every Ubuntu base stanza to ARM64 before installing REMnux. Otherwise i386 registration can break APT refresh and prevent dependent tools from installing. This restriction does not make x86 packages compatible with ARM64.

On a fresh Ubuntu 24.04 ARM64 VM the mirror and suites may already be correct while the explicit architecture restriction is missing. Back up the file and inspect **every active stanza**, including separate updates/security entries:

```bash
sudo install -d -m 0755 /var/backups
sudo cp -a /etc/apt/sources.list.d/ubuntu.sources \
  "/var/backups/ubuntu.sources.$(date +%Y%m%d-%H%M%S)"

sudo cat /etc/apt/sources.list.d/ubuntu.sources
```

Each active Ubuntu base stanza with `Types: deb` must contain exactly one `Architectures: arm64` field. If missing or different, edit that stanza while preserving its mirror, suites, components and signing key:

```bash
sudoedit /etc/apt/sources.list.d/ubuntu.sources
```

Add or correct this field in **each** applicable stanza (blank lines separate stanzas):

```text
Architectures: arm64
```

Do not rely on a file-wide `grep`. One correct stanza can hide another unrestricted one. Also check for `Architectures-Add` / `Architectures-Remove` fields that would undo the restriction. If all Ubuntu base stanzas are already explicitly ARM64-only, no edit is needed. Do not replace a healthy source file wholesale. Check other files that define Ubuntu base sources too. Legacy `.list` entries use `arch=arm64` inside their options. Third-party sources such as WineHQ are separate and must not be rewritten indiscriminately.

Now verify the active **package** indexes (filtering out architecture-independent targets that can print a literal `$(ARCHITECTURE)`):

```bash
sudo apt update
apt-get indextargets \
  --format '$(SITE) $(RELEASE) $(ARCHITECTURE) $(COMPONENT)' 'Identifier: Packages' |
  sort -u
apt-cache policy libc6:amd64 aeskeyfind:amd64 rar:amd64 edb-debugger:amd64
```

Ubuntu base entries should use `ports.ubuntu.com/ubuntu-ports` (or your intended ARM64 mirror) and `arm64`. Check that they cover `noble`, `noble-updates`, `noble-backports` and `noble-security`. The `libc6:amd64` and other amd64 probes should have no candidate. Continue with Step 2.2 only after both the per-stanza review and the index check pass. Third-party repositories may still show different architectures in the index list.

After the REMnux installer, **before running fixup**, repeat `sudo apt update` and the package-index check. Run `dpkg --print-foreign-architectures` as well. Even if `i386` is registered, Ubuntu base package targets must remain `arm64` with no Ports i386 targets or related 404 errors. If the check fails, repair the sources before continuing. Do not register i386 just for this check.

Only use the following repair if the validation shows an `archive.ubuntu.com` amd64/i386 stanza, ordinary Ubuntu amd64 candidates, or another mixed base-source configuration:

```bash
sudo tee /etc/apt/sources.list.d/ubuntu.sources >/dev/null <<'EOF'
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble noble-updates noble-backports noble-security
Components: main universe restricted multiverse
Architectures: arm64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

sudo apt clean
sudo apt update
```

If the VM deliberately uses a custom Ubuntu mirror or proxy, keep it and apply the same rule rather than copying the example verbatim. The active Ubuntu base indexes have to provide ARM64 packages and must not expose amd64 candidates.

After a repair, run the verification again:

```bash
apt-get indextargets \
  --format '$(SITE) $(RELEASE) $(ARCHITECTURE) $(COMPONENT)' 'Identifier: Packages' |
  sort -u
apt-cache policy libc6:amd64 aeskeyfind:amd64 rar:amd64 edb-debugger:amd64
```

Rollback if the replacement was wrong:

```bash
sudo cp -a /var/backups/ubuntu.sources.YYYYMMDD-HHMMSS \
  /etc/apt/sources.list.d/ubuntu.sources
sudo apt update
```

With a clean ARM64-only base configuration, nodejs and other native packages resolve from the ARM64 archive. Unavailable i386/Wine packages can then skip or fail without dragging ordinary amd64 Ubuntu packages into the transaction.

### 2.2 Build dependencies

Install these prerequisites **before** running REMnux. They supply the downloader and native build toolchain. Some packages still need the fixes in Step 4.

```bash
sudo apt install -y curl cmake build-essential openjdk-21-jdk
```

Why:

| Package | Purpose |
|---|---|
| `curl` | The REMnux installer needs it to run at all. |
| `cmake` + `build-essential` | Keystone builds from source on ARM64. These packages provide its toolchain. v2026.41.2 handles the build-isolation workaround upstream. Step 4.7 retains the fallback for older or failed installations. |
| `openjdk-21-jdk` | Needed later for Ghidra and its native-component build (the REMnux ghidra .deb won't install anyway, see Step 4). |

## Step 3 - Run the REMnux Installer

For a dedicated REMnux VM, use the default install mode from the REMnux "Install from Scratch" docs. Pin the salt-states release to this guide's tested baseline so the installer and the post-install fixes start from the same known state. `curl` should already be present from Step 2.2:

```bash
curl -O https://REMnux.org/remnux
chmod +x remnux
sudo mv remnux /usr/local/bin/
sudo remnux install --version=v2026.41.2   # dedicated mode, tested baseline
```

If you are adding REMnux to an existing Ubuntu system and want to keep more of its current look and feel, use addon mode instead:

```bash
sudo remnux install --mode=addon --version=v2026.41.2
```

This guide assumes dedicated mode. Addon mode keeps more of the existing desktop configuration, so some installation steps and results differ.

Leave off `--version` only when you actually want the latest salt-states release and accept that failure counts and required fixes may differ from this guide. In that case the fixup script will warn you when the detected release does not match its tested baseline. Pinning the state release helps reproducibility, but it does not freeze external apt, npm, PyPI, or upstream download contents.

Expectations on ARM64:

- The run takes a long time and **will report failures**. Review them and apply the post-install fixes. The [test results](docs/TEST-RESULTS.md) give examples, but your exact failure count may differ.
- Some unsupported tools are explicitly skipped on ARM64. Those notification states count as successful, but do not mean the tools were installed.
- Save the results YAML the installer writes so you can triage later. Current Cast-based installs keep the latest run at `/var/cache/cast/installer/logs/results.yaml`. Older installer runs may use paths such as `/var/cache/remnux/cli/<date>_results.yaml`.
- Do **not** blindly loop the installer hoping failures resolve. Distinguish architecture limitations and build failures from temporary download or network errors. Retry temporary failures after addressing the cause or waiting out a rate limit. Rerunning alone does not repair the structural failures described below.

`remnux results` is a handy first check. It prints the results file path, counts successful and failed states, and points you at `saltstack.log`. REMnux also ships `remnux-diag.py` to group root causes and dependent failures. If you want to compare releases, see [Comparing installer runs](docs/TEST-RESULTS.md#comparing-installer-runs).

**Record which salt-states release was installed** so you can match it against this guide. Do not rely on `/etc/remnux-version` after an incomplete installation. Its final state can fail because of earlier failures and leave it missing or outdated. Read the selected release from the installer log and cache instead. The release tag is the directory name:

```bash
ls -1dt /var/cache/cast/remnux_salt-states/v*/ | head -n 1
# e.g. /var/cache/cast/remnux_salt-states/v2026.41.2/
```

The current installer does not give you a stable `remnux version` subcommand. Passing `version` may only print its usage text. Use the cached salt-states release above for this guide's compatibility check.

## Step 4 - Post-Install Fixes

You can apply the fixes below by hand or use [tools/one-armed-remnux-fixup.sh](tools/one-armed-remnux-fixup.sh) after reading it. Run the script as your normal VM user. It invokes `sudo` where needed.

On v2026.41.2, PowerShell, FLOSS, Qiling/Keystone, Vivisect without its GUI and JStillery are handled upstream. The script checks existing installations and retains fallbacks for older releases. Ghidra installation and native builds, plus the Magika Python-client link, remain relevant fixes. Do not run every manual repair below on tools that already work.

The fixup does not rerun Salt or complete every configuration step that depended on a failed state. Installing Ghidra manually does not by itself complete its skipped Salt configuration or GhidrAssist-MCP setup.

The script stops if APT refresh, package repair or required build dependencies fail. Independent tool failures allow later steps to continue, but the final exit status remains nonzero. This also applies to the separate `7zip` and `p7zip-full` replacements. Review every `SKIP` message. Exit 0 means no failure was detected, not that every REMnux tool works. When logging through `tee`, use `set -o pipefail` and capture `${PIPESTATUS[0]}` immediately after the pipeline.

### 4.1 Handle the i386 foreign architecture

v2026.41.2 now skips i386 registration on ARM64. Older installations may still carry the registration and i386 package records. If packages use it, `dpkg --remove-architecture i386` correctly refuses with `architecture 'i386' currently in use by the database`. Do not force-purge those packages just to remove the architecture. That is unnecessary for APT health once the source validation in Step 2.1 passes. It also does nothing to make installed x86 Wine binaries run on native ARM64, see Step 5.

Check registration and package records first. If i386 is not registered, skip this step.

```bash
dpkg --print-foreign-architectures
dpkg-query -W -f='${binary:Package}\t${Architecture}\t${db:Status-Abbrev}\n' 2>/dev/null |
  awk '$2 == "i386" && $3 != "un" {print $1, $3}'
```

If the command prints packages, leave i386 registered and ensure every Ubuntu base stanza is explicitly restricted to ARM64 as in Step 2.1. If it prints nothing, removing the unused architecture is optional hygiene **after that restriction is in place**:

```bash
sudo dpkg --remove-architecture i386
sudo apt update
```

If you skipped the Step 2.1 restriction, i386 registration can make `apt update` fail against Ubuntu Ports. Restrict the Ubuntu base sources first. Removing unused i386 can clear the symptom, but an older installer or another package workflow could register it again. Removing i386 on its own does not repair a separate `archive.ubuntu.com`/amd64 source block.

### 4.2 Clean up dpkg/apt

```bash
sudo dpkg --configure -a
sudo apt --fix-broken install -y
```

### 4.3 nodejs + npm tools (only if missing)

If `node`, `npm`, and the listed global packages are already installed, skip this step. If they are missing, check APT and the source restrictions in Step 2.1 first. The installer should already have configured the NodeSource repository.

```bash
sudo apt install -y nodejs
sudo npm install -g box-js webcrack js-deobfuscator opencode-ai @remnux/mcp-server
sudo npm install -g git+https://github.com/mindedsecurity/JStillery.git
sudo ln -sf "$(npm root -g)/JStillery_Server/jstillery_cli.js" /usr/local/bin/jstillery
```

JStillery names its installed package directory `JStillery_Server` and does not declare an npm `bin` entry. REMnux supplies `/usr/bin/jstillery`. The manual symlink above is only needed if that command is missing.

### 4.4 Replacements from Ubuntu repos

v2026.41.2 installs an upstream ARM64 build of `7zz`. The Ubuntu packages below remain fallbacks for missing archive tools and older releases. `rar` is skipped on ARM64.

```bash
sudo apt install -y 7zip p7zip-full
sudo apt install -y unrar || sudo apt install -y unrar-free
```

On Ubuntu, `unrar` may need the `multiverse` repository. If you would rather not enable `multiverse`, install `unrar-free` as the safe baseline and add the non-free `unrar` only when you need better RAR compatibility.

### 4.5 Ghidra (including the decompiler)

The REMnux PPA ghidra .deb is amd64-only. Ghidra itself runs on aarch64, but the release ZIP bundles native components (decompiler, sleigh compiler, demangler) only for `linux_x86_64`. Without building them the GUI starts but complains about **missing essential components**, and decompilation does not work.

The script pins [Ghidra **12.1.4**](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.1.4_build). It does not upgrade an existing installation at `/opt/ghidra`, even when release overrides are set. The manual block below is intended for a missing installation.

```bash
# Download and extract the tested release.
# The companion script accepts GHIDRA_ZIP/GHIDRA_TAG/GHIDRA_URL overrides.
GHIDRA_ZIP="ghidra_12.1.4_PUBLIC_20260921.zip"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/${GHIDRA_ZIP}"
cd /tmp && wget "${GHIDRA_URL}"
sudo unzip -q "${GHIDRA_ZIP}" -d /opt/
sudo ln -sf /opt/ghidra_12.1.4_PUBLIC /opt/ghidra
sudo ln -sf /opt/ghidra/ghidraRun /usr/local/bin/ghidra
rm -f "${GHIDRA_ZIP}"

# Build native components for linux_arm_64.
# NOTE: release ZIPs do NOT contain support/buildNatives (that script only
# exists in the source repo). The correct way is the bundled Gradle wrapper:
cd /opt/ghidra/support/gradle/
sudo chmod +x gradlew        # release ZIP does not mark it executable
sudo ./gradlew buildNatives  # ~1 min; needs internet on first run
```

Output lands in the modules' `build/os/linux_arm_64/` directories, which Ghidra prefers over the shipped `os/linux_x86_64/` binaries. Verify the build by opening a harmless binary like `/usr/bin/true` in Ghidra, running auto-analysis and checking that the Decompiler displays C-like code for a function.

### 4.6 PowerShell

On amd64, REMnux installs the `powershell` APT package from Microsoft's repo. On ARM64, v2026.41.2 installs PowerShell 7.6.6 from Microsoft's `linux-arm64` tarball under `/opt/microsoft/powershell/7.6.6` and links `pwsh` to it.

For a missing installation, the fixup script pins [PowerShell **7.6.6**](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6). Set `PWSH_VER` to choose another release, or use `PWSH_VER=latest` to resolve GitHub's latest stable release at installation time.

**The fixup script does not upgrade existing PowerShell installations.** It only installs PowerShell when `pwsh` is absent, even if `PWSH_VER` is set to a newer version or `latest`. REMnux's own upgrade can replace the command link with its managed version. The manual block below is also intended for a missing installation.

```bash
PWSH_VER="${PWSH_VER:-7.6.6}"   # pinned and VM-tested release
if [ "${PWSH_VER}" = "latest" ]; then
  PWSH_VER="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"
fi
curl -fsSL -o /tmp/powershell.tar.gz \
  "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/powershell-${PWSH_VER}-linux-arm64.tar.gz"
sudo mkdir -p /opt/microsoft/powershell/7
sudo tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7
sudo chmod +x /opt/microsoft/powershell/7/pwsh
sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
```

### 4.7 qiling

On ARM64, qiling's `keystone-engine` dependency builds from source. With pip 26.2.1, the default isolated build can fail with missing standard-library modules such as `__future__` and `traceback`. The commands below use pip's standard-venv isolation workaround. Run them only if qiling is not already functional. The companion script checks whether the installed pip supports this feature before selecting it.

v2026.41.2 handles this upstream by installing the build dependencies and building Keystone separately with `--no-build-isolation`. The fixup leaves a working Qiling/Keystone environment in place.

```bash
sudo /opt/qiling/bin/python -m pip install \
  --use-feature=venv-isolation 'keystone-engine==0.9.2'
sudo /opt/qiling/bin/python -m pip install \
  --use-feature=venv-isolation qiling
sudo ln -sf /opt/qiling/bin/qltool /usr/local/bin/qltool

/opt/qiling/bin/python - <<'PY'
from keystone import Ks, KS_ARCH_X86, KS_MODE_32
from qiling import Qiling

ks = Ks(KS_ARCH_X86, KS_MODE_32)
assert ks.asm("nop")[0] == [0x90]
print("Keystone and Qiling imports: OK")
PY
```

### 4.8 vivisect (CLI, no GUI)

v2026.41.2 installs Vivisect without its GUI on ARM64. The `vivisect[gui]` extra pulls PyQt5 from PyPI, which has no suitable wheel for this Python 3.12/aarch64 venv. Ubuntu does ship `python3-pyqt5`, but it does not satisfy this isolated pip install cleanly. Use the fallback below only if Vivisect is missing from an existing `/opt/vivisect` environment:

```bash
sudo /opt/vivisect/bin/pip install vivisect   # without [gui] extra
sudo ln -sf /opt/vivisect/bin/vivbin /usr/local/bin/vivbin
sudo ln -sf /opt/vivisect/bin/vdbbin /usr/local/bin/vdbbin
```

### 4.9 FLOSS

REMnux v2026.41.2 installs FLOSS from PyPI in `/opt/flare-floss`, including on ARM64. The companion script checks this installation first and leaves it and its command links unchanged when the checks pass. If the environment is present but broken or `/usr/local/bin/floss` does not resolve to its executable, the script reports a failure instead of hiding the problem with another installation.

Older releases used an x86-only `flare-floss` package. When `/opt/flare-floss` is absent, the script retains the `/opt/floss` fallback below. Its `binary2strings` dependency compiles a native aarch64 extension from source. Install `python3-dev` and `build-essential` to provide the required toolchain. Only use this manual block when the upstream installation is absent.

```bash
sudo apt install -y python3-venv python3-dev build-essential
sudo python3 -m venv /opt/floss
sudo /opt/floss/bin/python -m pip install --upgrade pip setuptools wheel
sudo /opt/floss/bin/python -m pip install 'flare-floss==3.1.1'
sudo ln -sf /opt/floss/bin/floss /usr/local/bin/floss
floss -h
```

The fallback uses the same tested version by default. Set `FLOSS_VER` to select a version when installing the fallback. It does not upgrade an existing working installation or override the upstream environment. On older releases, the Salt state will still report the missing REMnux package even after the fallback is installed.

### 4.10 Magika Python client on ARM64

REMnux installs Magika in `/opt/magika` and links `/usr/local/bin/magika` to the package's primary entrypoint. When the Python package has no compatible precompiled Rust client for ARM64, that entrypoint only prints a warning. The supported Python fallback is installed alongside it but is not linked into the normal command path. Expose the fallback without replacing `magika`, so a future native ARM64 Rust client can still take over that command:

```bash
sudo ln -sf /opt/magika/bin/magika-python-client \
  /usr/local/bin/magika-python-client
magika-python-client --version
magika-python-client /etc/os-release
```

ONNX Runtime may print `cpuid_info warning: Unknown CPU vendor` under virtualization. That warning alone does not mean classification failed. Check the result and exit status.

### 4.11 peframe (optional, manual)

peframe-ds depends on the old Python `readline` 6.2 package, whose build configuration does not recognize aarch64. The manual workaround skips that dependency and uses CPython's existing readline support.

```bash
sudo /opt/peframe/bin/pip install --no-deps peframe-ds
sudo /opt/peframe/bin/pip install pefile requests python-magic yara-python oletools cryptography
sudo ln -sf /opt/peframe/bin/peframe /usr/local/bin/peframe
```

This bypasses dependency resolution. A future peframe-ds release may need extra packages installed by hand, so the workaround is not part of the automated script.

## Step 5 - Probably Not Worth Fixing IMHO (and what to use instead)

These gaps include architecture limitations and unavailable packages in the tested REMnux installation path. A missing ARM64 package does not necessarily mean the upstream tool cannot run on ARM64. Use alternatives where practical.

v2026.41.2 explicitly skips many of these tools rather than attempting an incompatible installation. A successful skip notification is not a working tool.

### Blocked by missing aarch64 wheels/libraries

| Tool | Root cause | Alternative |
|---|---|---|
| **thug** | STPyV8 ships x86_64-only Linux wheels | amd64 REMnux container (see below), or online analysis (urlscan.io, ANY.RUN) |
| **peepdf-3** | Same STPyV8 issue | `pdf-parser.py`, `pdfid.py` (Didier Stevens, installed and native) cover most workflows |
| **pe-tree** | PyPI PyQt5 dependency has no suitable wheel for this Python 3.12/aarch64 venv | `pefile` scripting, `readpe`, Ghidra's PE loader |
| **js-patched** | Needs i386 (32-bit x86) libraries, impossible on aarch64 | `js115` (SpiderMonkey 115) is installed and registered as the `js` alternative, and a better engine for JS deobfuscation anyway IMHO |
| **wine** | Native ARM64 lacks i386 multilib. Current REMnux states may skip cleanly or appear green, but the usual x86 Wine-dependent workflows are not available through native REMnux | amd64 REMnux container for Wine-dependent workflows. For running x86 Windows apps natively on ARM64 Linux, [Hangover](https://github.com/AndreRH/hangover) (Wine + FEX/Box64, prebuilt arm64 .debs incl. Ubuntu 24.04) exists. Experimental and not REMnux-integrated, but no longer impossible |
| **shellcode2exe.bat** | Runs under Wine | Analyze shellcode directly with `speakeasy` or qiling instead of wrapping it in a PE |
| **ssview** | Windows tool (MSI/structured storage viewer) under Wine | `oledir`, `olebrowse`, `oleid` from oletools (installed, native) |

### Tools without a usable ARM64 package in this install path

| Tool | Alternative |
|---|---|
| **scdbg** | `speakeasy` (Mandiant, pure Python + unicorn, runs on aarch64) or qiling for shellcode emulation, or an amd64 container for the real thing |
| **binee** | `speakeasy` covers the Windows-emulation use case |
| **edb-debugger** | `gdb` + gef/pwndbg (native aarch64), radare2 |
| **detect-it-easy** | Linux ARM64 currently means building from source, use horsicq/DIE-engine as the build/release repo |

The installer also skips AESKeyFinder, runsc, Bytehist, Malcat Lite and TrID on ARM64. Older package-failure lists are retained in the [test history](docs/TEST-RESULTS.md). Successful package installation alone does not establish runtime compatibility.

### Quick source builds (only if actually needed)

`aeskeyfind`, `pycdc`, `manalyze`, `bearparser`, `sandfly-processdecloak` (Go) are all small C/C++/Go projects that compile on aarch64 in minutes with cmake/make/go. Build them on demand rather than preemptively.

`xorsearch` and `xorstrings` belong here too, not in the "use an alternative" bucket. Didier Stevens ships them as portable single-file C sources (download from <https://blog.didierstevens.com/programs/xorsearch/>), deliberately written to build with any standard C compiler. Run `gcc -o xorsearch XORSearch.c` and you are done. Until you build them, `xortool` (installed) and `bbcrack` (balbuzard) cover the same ground.

## Sample Handling (In/Egress)

The rules exist because of the macOS host, not despite it. An unarchived sample on the Mac gets indexed by Spotlight, may get quarantined or silently deleted by XProtect/Gatekeeper (evidence gone), and a folder under `~/Documents` or `~/Desktop` with iCloud sync on will happily upload your malware collection to the cloud.

**Ground rule: on the host, samples exist only as password-protected archives** (`infected` convention), never unpacked. Unpacking happens inside the VM.

### Getting samples in (order of preference)

1. **Fetch inside the VM** (webmail, download portal, MalwareBazaar & co. in the REMnux browser) so the sample never touches the host. Use a dedicated mailbox or app-specific password for sample delivery, not your primary account session. The VM parses hostile files all day, and analysis tooling has had parser exploits. Fetch, then disconnect, same rhythm as the update workflow.
2. **`scp`/`sftp` from host to VM** over the vmnet. No persistent mount, nothing to forget open.
3. **Shared folder, if you must:** a dedicated directory, shared **read-only** into the VM (host-to-VM one-way), excluded from Spotlight, Time Machine, and iCloud, and disconnected when you are not actively transferring. A writable share is a host directory that malware or a compromised tool in the VM can reach.

### On receipt

```bash
cd /home/remnux/files/samples        # matches the MCP server layout
sha256sum sample.bin | tee -a ../sample-hashes.txt
chmod -x sample.bin
```

Hash first, record it, strip the execute bit. The hash note doubles as a minimal receiving log.

### Getting results out

- Text artifacts (reports, IOC lists, strings output, INetSim logs) move freely. They are the product.
- The sample itself only leaves the VM re-archived with a password plus its hash, e.g. `7z a -pinfected sample.7z sample.bin`.
- Nothing ever egresses from a dirty victim VM. Revert or refresh those from the golden image instead.

## Fallback: amd64 REMnux via emulation

For the handful of genuinely x86-only tools, run the official REMnux container image under qemu user-mode emulation rather than maintaining a second VM. You do this **inside the Ubuntu ARM64 guest**, not on the macOS host, so the emulated tools live right next to the native ones:

```bash
sudo apt install -y qemu-user-static
docker run --rm -it --platform linux/amd64 docker.io/remnux/remnux-distro:noble bash
# (check hub.docker.com/u/remnux for current tags)
```

Docker is already present, since the REMnux installer sets it up as part of the distro. If you prefer Podman, it works the same way (`sudo apt install -y podman`, same `--platform` flag).

Emulation is roughly 5 to 10 times slower than native. Fine for occasionally running scdbg or thug against a sample, not for daily use.

If the missing x86_64 tools matter more than occasionally, UTM is worth a look as an alternative host for the ARM64 VM. UTM can run ARM64 Linux via Apple's virtualization stack and expose Rosetta to Linux guests, which can make amd64 userspace and containers much more pleasant than plain QEMU emulation. UTM itself is free and open source via GitHub. The Mac App Store build is paid, identical in features, and mainly buys you automatic updates plus support for the project.

> [!NOTE]
> Apple's Rosetta phase-out concerns Intel **macOS apps**. General support lasts through macOS 27. From macOS 28, only certain older games retain support. See [Apple's announcement](https://support.apple.com/en-us/102527).
>
> Intel **Linux binaries in ARM VMs** are a separate case. Apple documents built-in translation from macOS 27 without a separate Rosetta installation. This is not an announced removal of the Linux fallback described here. A compatible VM application and guest configuration are still required. See [Apple's Linux VM documentation](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms).

**Other options considered:**

- **SIFT Workstation** - the classic combo is SIFT as the base plus `remnux install --mode=addon` on top. Both distros use the same Cast/Salt installer, so one VM can carry both. Like REMnux, [SIFT](https://www.sans.org/tools/sift-workstation) is officially x86_64-only. ARM64 is tracked upstream ([teamdfir/sift #592](https://github.com/teamdfir/sift/issues/592)) and a community port exists ([sift-on-arm](https://github.com/jonathanlooi/sift-on-arm)) with reportedly most core tools (sleuthkit, volatility3, wireshark) working. **Untested here.** If I run a combined install, its failure analysis will land in this repo.
- **Kali ARM64** - excellent native ARM64 support, but its catalog overlaps little with the *missing* REMnux tools (scdbg, thug, js-patched are not packaged there either). Useful as a companion for network/pentest tooling, not as a replacement for the gaps.
- **Full x86_64 REMnux VM** - VMware Fusion on Apple Silicon cannot run x86_64 VMs. UTM/QEMU can emulate one, but full-system x86_64 emulation is slow. Prefer an ARM64 VM plus container/Rosetta escape hatches unless you explicitly need a complete x86_64 guest.
- **Rosetta for Linux** - Apple's Virtualization framework can translate x86_64 Linux programs inside an ARM64 guest. This requires a VM application that exposes the feature, plus guest setup and any required x86_64 libraries. It does not run a full x86_64 guest OS. The native VMware Fusion setup in this guide does not depend on it.

## Result

The [test results](docs/TEST-RESULTS.md) cover fresh installation, upgrades, repeated fixup runs and focused tool checks. They also list the remaining validation gaps and earlier results. A successful fixup does not make every x86-only REMnux tool available on ARM64.

## License

- Documentation (this guide and all Markdown files): [CC BY 4.0](LICENSE) - republish, translate, adapt freely, keep the attribution.
- Code under `tools/`: [MIT](tools/LICENSE).
