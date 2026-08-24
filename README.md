<p align="center">
  <img src="images/oar_logo_light.png" alt="one-ARMed-REMnux logo" width="320">
</p>

REMnux officially only supports x86_64, but you can still run it inside an Ubuntu 24.04 ARM64 (aarch64) guest VM on VMware Fusion and about 90% of the tooling installs and works on ARM64 anyway.

The fixes below clear up most of the avoidable ARM64 failures. Exact counts move with every salt-states release and depend on how you prepare the box first. My earlier `--mode=addon` tests hit the same package and tool failure classes, though addon mode skips some full-environment configuration on purpose. REMnux ships several signed releases a week (`vYYYY.week.release`, over at https://github.com/REMnux/salt-states/releases), so the states keep drifting. Your mileage will vary.

This is a write-up of what actually worked for me. It walks through preparation, the install, the post-install fixes, and which failures I decided to just live with. It assumes you have open internet access while installing and updating. Once that is done, the analysis work can run fully offline. I try to keep it somewhat up-to-date, and pull requests are always welcome.

> [!IMPORTANT]
> **Last tested version:**
>
> - REMnux salt-states: **v2026.34.3** (tested 2026-08-24)
> - Installation: fresh Ubuntu 24.04 ARM64 VM, default/dedicated mode (`sudo remnux install --version=v2026.34.3`)
> - Result before this guide's post-install fixes: **960/1071 states succeeded**

## Contents

- [Step 1 - VM Setup](#step-1---vm-setup)
- [Step 2 - Pre-Install Preparation](#step-2---pre-install-preparation) (`apt` arm64 pinning, build dependencies)
- [Step 3 - Run the REMnux Installer](#step-3---run-the-remnux-installer)
- [Step 4 - Post-Install Fixes](#step-4---post-install-fixes) (apt cleanup, nodejs, Ghidra, PowerShell, qiling, FLOSS, vivisect, peframe)
- [Step 5 - Not Worth Fixing](#step-5---probably-not-worth-fixing-imho-and-what-to-use-instead)
- [Sample Handling (In/Egress)](#sample-handling-inegress)
- [Fallback: amd64 REMnux via emulation](#fallback-amd64-remnux-via-emulation)
- [Result](#result)

## Step 1 - VM Setup

1. Create the VM in VMware Fusion: Ubuntu 24.04 ARM64, recommend ≥4 vCPU, ≥8 GB RAM, ≥60 GB disk (the full REMnux install is large, plus samples and build artifacts).
2. Install Ubuntu 24.04 ARM64 (Desktop or Server + your preferred DE). See <https://docs.remnux.org/install-distro/install-from-scratch#install-ubuntu>
3. Install VMware guest tools:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y open-vm-tools open-vm-tools-desktop
```

4. **Take a VM snapshot now.** The REMnux installer runs for a good while and changes the system heavily, so a clean pre-install snapshot is your cheapest way back. 

## Step 2 - Pre-Install Preparation

### 2.1 Validate and back up the Ubuntu base sources

On ARM64, the Ubuntu base packages have to come from `ports.ubuntu.com/ubuntu-ports` as `arm64`. A mixed Deb822 configuration file can contain one correct ARM64 stanza plus a second `archive.ubuntu.com` stanza carrying `Architectures: amd64 i386`. When that happens, apt starts offering ordinary amd64 packages such as `aeskeyfind`, `rar`, and `edb-debugger`, which dpkg then rejects on the ARM64 system. So a simple grep for any `Architectures: arm64` line is not enough on its own.

REMnux may also register i386 for Wine. Keeping the Ubuntu base source ARM64-only stops that foreign architecture from breaking or contaminating normal Ubuntu package resolution.

On a fresh Ubuntu 24.04 ARM64 VM the standard source configuration should already be correct. Back it up and verify the indexes apt is actually using. Do not replace a healthy source file:

```bash
sudo install -d -m 0755 /var/backups
sudo cp -a /etc/apt/sources.list.d/ubuntu.sources \
  "/var/backups/ubuntu.sources.$(date +%Y%m%d-%H%M%S)"

sudo apt update
apt-get indextargets \
  --format '$(SITE) $(RELEASE) $(ARCHITECTURE) $(COMPONENT)' |
  sort -u
apt-cache policy libc6:amd64 aeskeyfind:amd64 rar:amd64 edb-debugger:amd64
```

Expected output: Ubuntu base entries use `ports.ubuntu.com/ubuntu-ports` and `arm64`, and `libc6:amd64` and the other amd64 probes have no candidate. If that is what you see, continue with Step 2.2. Architecture-specific third-party repositories such as WineHQ are a separate matter and may still show up in the index list.

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
  --format '$(SITE) $(RELEASE) $(ARCHITECTURE) $(COMPONENT)' |
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

Installing these **before** you run the REMnux installer stops several failures from ever happening:

```bash
sudo apt install -y curl cmake build-essential openjdk-21-jdk
```

Why:

| Package | Prevents |
|---|---|
| `curl` | The REMnux installer needs it to run at all. |
| `cmake` + `build-essential` | qiling's dependency keystone-engine (a C++ assembler library with a Python wrapper) ships pre-compiled packages ("wheels") only for x86_64, so on aarch64 pip falls back to compiling the C++ source at install time. These packages provide the required toolchain, and pip 26.2.x also needs the build-isolation workaround in Step 4.7. |
| `openjdk-21-jdk` | Needed later for Ghidra and its native-component build (the REMnux ghidra .deb won't install anyway, see Step 4). |

## Step 3 - Run the REMnux Installer

For a dedicated REMnux VM, use the default install mode from the REMnux "Install from Scratch" docs. Pin the salt-states release to this guide's tested baseline so the installer and the post-install fixes start from the same known state. `curl` should already be present from Step 2.2:

```bash
curl -O https://REMnux.org/remnux
chmod +x remnux
sudo mv remnux /usr/local/bin/
sudo remnux install --version=v2026.34.3   # dedicated mode, tested baseline
```

If you are adding REMnux to an existing Ubuntu system and want to keep more of its current look and feel, use addon mode instead:

```bash
sudo remnux install --mode=addon --version=v2026.34.3
```

This guide's counts and post-install expectations refer to the default/dedicated mode. The ARM64 package and tool failures should be largely the same in addon mode, but desktop and configuration states can differ.

Leave off `--version` only when you actually want the latest salt-states release and accept that failure counts and required fixes may differ from this guide. In that case the fixup script will warn you when the detected release does not match its tested baseline. Pinning the state release helps reproducibility, but it does not freeze external apt, npm, PyPI, or upstream download contents.

Expectations on ARM64:

- The run takes a long time and **will report failures**. On the v2026.34.3 default-mode test, 111 of 1071 states failed. That is expected and mostly harmless.
- Save the results YAML the installer writes so you can triage later. Current Cast-based installs keep the latest run at `/var/cache/cast/installer/logs/results.yaml`. Older installer runs may use paths such as `/var/cache/remnux/cli/<date>_results.yaml`.
- Do **not** loop the installer hoping failures resolve. The failures are architectural, not transient.

`remnux results` is a handy first check. It prints the results file path, counts successful and failed states, and points you at `saltstack.log`. REMnux also ships `remnux-diag.py`, which is better for diagnosing a single run because it groups root causes and cascades and can pull in `saltstack.log` for extra context. Neither one gives you a failed-only, normalized artifact for comparing installs.

For stable comparisons between runs I've added `tools/remnux-results-normalize.py`. Copy the YAML with a versioned name and normalize it:

```bash
python3 -m pip install pyyaml
sudo cp /var/cache/cast/installer/logs/results.yaml results.yaml_v2026.34.3
sudo chown "$USER":"$USER" results.yaml_v2026.34.3
python3 tools/remnux-results-normalize.py results.yaml_v2026.34.3 \
  --format json -o v2026.34.3_failed-states.json
python3 tools/remnux-results-normalize.py old_failed-states.json --compare v2026.34.3_failed-states.json \
  --format markdown -o old_vs_v2026.34.3_failed-state-diff.md
```

The normalizer keeps only `result: false` states, drops volatile fields such as `__run_num__`, `duration`, and `start_time`, removes noisy one-off text, sorts requisite cascades, and separates direct failures from requisite cascades. Compare the JSON outputs when you want the most stable diff, and render Markdown when you want something readable.

**Record which salt-states release was installed** so you can match it against this guide. Note that `/etc/remnux-version` is never written on ARM64. It's the final Salt state and always cascade-fails, so read the version from the installer cache instead. The release tag is the directory name:

```bash
ls -1dt /var/cache/cast/remnux_salt-states/v*/ | head -n 1
# e.g. /var/cache/cast/remnux_salt-states/v2026.34.3/
```

The current installer does not give you a stable `remnux version` subcommand. Passing `version` may only print its usage text. Use the cached salt-states release above for this guide's compatibility check.

## Step 4 - Post-Install Fixes

The steps below are the primary, auditable fix path. If you would rather automate them after reading the code, run the companion script `tools/one-armed-remnux-fixup.sh`. All steps are verified working on this setup.

### 4.1 Handle the i386 foreign architecture

REMnux registers i386 for Wine, and some installations may already carry i386 package records. When they do, `dpkg --remove-architecture i386` correctly refuses with `architecture 'i386' currently in use by the database`. Do not force-purge those packages just to remove the architecture. That is invasive and unnecessary for apt health once the source validation in Step 2.1 passes. It also does nothing to make the installed x86 Wine binaries run on native ARM64, see Step 5.

First inspect the records:

```bash
dpkg-query -W -f='${binary:Package}\t${Architecture}\t${db:Status-Abbrev}\n' 2>/dev/null |
  awk '$2 == "i386" && $3 != "un" {print $1, $3}'
```

If the command prints packages, leave i386 registered. This is safe once the source validation in Step 2.1 passes. If it prints nothing, removing the unused architecture is optional hygiene:

```bash
sudo dpkg --remove-architecture i386
sudo apt update
```

If you skipped the Step 2.1 validation or it failed, go back to it and repair the Ubuntu base sources first. Removing i386 on its own does not repair a separate `archive.ubuntu.com`/amd64 source block.

### 4.2 Clean up dpkg/apt

```bash
sudo dpkg --configure -a
sudo apt --fix-broken install -y
```

### 4.3 nodejs + npm tools (only if missing)

With clean ARM64 base sources, REMnux normally installs nodejs and the node-based tools during the main run. In the contaminated-source test run they failed as collateral when an apt refresh broke. That is one observed cause, not a reason to reinstall them every time. If `node`, `npm`, and the listed global packages are already there, skip this step. Otherwise the NodeSource repo should already be configured by the installer:

```bash
sudo apt install -y nodejs
sudo npm install -g box-js webcrack js-deobfuscator opencode-ai @remnux/mcp-server
sudo npm install -g git+https://github.com/mindedsecurity/JStillery.git
sudo ln -sf "$(npm root -g)/JStillery_Server/jstillery_cli.js" /usr/local/bin/jstillery
```

JStillery names its installed package directory `JStillery_Server` and does not declare an npm `bin` entry, so the explicit symlink gives you the expected `jstillery` command.

### 4.4 Replacements from Ubuntu repos

```bash
sudo apt install -y 7zip p7zip-full
sudo apt install -y unrar || sudo apt install -y unrar-free
```

Replaces the amd64-only REMnux PPA packages `7zz` and `rar`. On Ubuntu, `unrar` may need the `multiverse` repository. If you would rather not enable `multiverse`, install `unrar-free` as the safe baseline and add the non-free `unrar` only when you need better RAR compatibility.

### 4.5 Ghidra (including the decompiler)

The REMnux PPA ghidra .deb is amd64-only. Ghidra itself runs on aarch64, but the release ZIP bundles native components (decompiler, sleigh compiler, demangler) only for `linux_x86_64`. Without building them the GUI starts but complains about **missing essential components**, and decompilation does not work.

```bash
# Download and extract (check releases page for current version).
# The companion script accepts GHIDRA_ZIP/GHIDRA_TAG/GHIDRA_URL overrides.
GHIDRA_ZIP="ghidra_12.1.2_PUBLIC_20260605.zip"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.2_build/${GHIDRA_ZIP}"
cd /tmp && wget "${GHIDRA_URL}"
sudo unzip -q "${GHIDRA_ZIP}" -d /opt/
sudo ln -sf /opt/ghidra_12.1.2_PUBLIC /opt/ghidra
sudo ln -sf /opt/ghidra/ghidraRun /usr/local/bin/ghidra
rm -f "${GHIDRA_ZIP}"

# Build native components for linux_arm_64.
# NOTE: release ZIPs do NOT contain support/buildNatives (that script only
# exists in the source repo). The correct way is the bundled Gradle wrapper:
cd /opt/ghidra/support/gradle/
sudo chmod +x gradlew        # release ZIP does not mark it executable
sudo ./gradlew buildNatives  # ~1 min; needs internet on first run
```

Output lands in the modules' `build/os/linux_arm_64/` directories, which Ghidra prefers over the shipped `os/linux_x86_64/` binaries. After that Ghidra launches cleanly with a fully working decompiler.

### 4.6 PowerShell

On amd64, REMnux installs the `powershell` APT package from Microsoft's repo, so it picks up whatever stable version that repo currently offers. On ARM64, Microsoft does not provide an Ubuntu `.deb`, but it does publish official `linux-arm64` tarballs on GitHub. The script defaults to a tested version. Set `PWSH_VER=latest` to track GitHub's latest stable release:

```bash
PWSH_VER="${PWSH_VER:-7.6.3}"   # known-good; set PWSH_VER=latest for newest stable
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

On ARM64, qiling's `keystone-engine` dependency has to build from source. With pip 26.2.1 in salt-states v2026.34.3, the default isolated build leaked the REMnux-created virtualenv into Keystone's old LLVM Python helper and failed with missing standard-library modules such as `__future__` and `traceback`. pip's standard-venv isolation feature avoids that leak and produced a working native `manylinux1_aarch64` wheel. Run this only when the installer did not leave qiling functional:

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

The `vivisect[gui]` extra pulls PyQt5 from PyPI, which has no suitable wheel for this Python 3.12/aarch64 venv. Ubuntu does ship `python3-pyqt5`, but it does not satisfy this isolated pip install cleanly. The CLI works fine without it:

```bash
sudo /opt/vivisect/bin/pip install vivisect   # without [gui] extra
sudo ln -sf /opt/vivisect/bin/vivbin /usr/local/bin/vivbin
sudo ln -sf /opt/vivisect/bin/vdbbin /usr/local/bin/vdbbin
```

### 4.9 FLOSS

The REMnux `flare-floss` package is not available for ARM64, but the upstream Python package works in an isolated venv. Its `binary2strings` dependency compiles a native aarch64 extension from source, and `python3-dev` plus `build-essential` provide the required toolchain. Version 3.1.1 was verified on this VM with Python 3.12 by extracting static strings and running stack, tight, and decoded-string analysis against a 32-bit x86 PE file.

```bash
sudo apt install -y python3-venv python3-dev build-essential
sudo python3 -m venv /opt/floss
sudo /opt/floss/bin/python -m pip install --upgrade pip setuptools wheel
sudo /opt/floss/bin/python -m pip install 'flare-floss==3.1.1'
sudo ln -sf /opt/floss/bin/floss /usr/local/bin/floss
floss -h
```

The companion script uses the same tested version by default. Set `FLOSS_VER` to override it. The Salt state will still report the missing REMnux package, but the `floss` command works after this fix.

### 4.10 peframe (optional, manual)

peframe-ds hard-depends on the Python `readline` 6.2 package, whose 2008-era `config.guess` does not recognize aarch64, so the dependency cannot build. The `--no-deps` route **works in practice** though (verified on this VM), because CPython's built-in readline support makes the package redundant at runtime.

```bash
sudo /opt/peframe/bin/pip install --no-deps peframe-ds
sudo /opt/peframe/bin/pip install pefile requests python-magic yara-python oletools cryptography
sudo ln -sf /opt/peframe/bin/peframe /usr/local/bin/peframe
```

Caveat: this bypasses dependency resolution, so a future peframe-ds release may need extra packages installed by hand. That is why it is not in the automated script.

## Step 5 - Probably Not Worth Fixing IMHO (and what to use instead)

These failures are architectural. Accept them and use the alternatives.

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

### x86-only binaries from the REMnux PPA

| Tool | Alternative |
|---|---|
| **scdbg** | `speakeasy` (Mandiant, pure Python + unicorn, runs on aarch64) or qiling for shellcode emulation, or an amd64 container for the real thing |
| **binee** | `speakeasy` covers the Windows-emulation use case |
| **edb-debugger** | `gdb` + gef/pwndbg (native aarch64), radare2 |
| **signsrch** | YARA rule packs, `binwalk` |
| **evilclippy / ilspycmd** | Install .NET 8 SDK (ARM64 available), then `dotnet tool install -g ilspycmd`, and build evilclippy with the same SDK |
| **burpsuite-community** | PortSwigger provides a native Linux ARM64 installer - download directly |
| **jd-gui** | Java - download the jar from github.com/java-decompiler/jd-gui and run it directly |
| **baksmali/smali** | Java - jars from github.com/google/smali (current upstream, older releases lived under JesusFreke/smali) |
| **detect-it-easy** | Linux ARM64 currently means building from source, use horsicq/DIE-engine as the build/release repo |

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

**Other options considered:**

- **SIFT Workstation** - the classic combo is SIFT as the base plus `remnux install --mode=addon` on top. Both distros use the same Cast/Salt installer, so one VM can carry both. Like REMnux, [SIFT](https://www.sans.org/tools/sift-workstation) is officially x86_64-only. ARM64 is tracked upstream ([teamdfir/sift #592](https://github.com/teamdfir/sift/issues/592)) and a community port exists ([sift-on-arm](https://github.com/jonathanlooi/sift-on-arm)) with reportedly most core tools (sleuthkit, volatility3, wireshark) working. **Untested here.** If I run a combined install, its failure analysis will land in this repo.
- **Kali ARM64** - excellent native ARM64 support, but its catalog overlaps little with the *missing* REMnux tools (scdbg, thug, js-patched are not packaged there either). Useful as a companion for network/pentest tooling, not as a replacement for the gaps.
- **Full x86_64 REMnux VM** - VMware Fusion on Apple Silicon cannot run x86_64 VMs. UTM/QEMU can emulate one, but full-system x86_64 emulation is slow. Prefer an ARM64 VM plus container/Rosetta escape hatches unless you explicitly need a complete x86_64 guest.
- **Rosetta for Linux** - Apple's Virtualization framework can expose Rosetta to Linux guests, but this is supported by UTM/Parallels, not by VMware Fusion. If you ever migrate the VM to UTM, x86_64 binaries (and amd64 containers) run near-native via Rosetta + binfmt.

## Result

Numbers from the clean 2026-08-24 default-mode install with salt-states v2026.34.3:

| Stage | Result | Outcome |
|---|---|---|
| REMnux installer | 960 succeeded, 111 failed | 39 root-cause failures and 72 cascades before post-install fixes |
| Automated fix path | All 10 script sections have a verified ARM64 path | apt validation, nodejs/npm, Ghidra natives, PowerShell, qiling/Keystone, FLOSS, and vivisect CLI |
| Accepted gaps | See Step 5 | Wine/x86 workflows, STPyV8, PyQt5 GUI dependencies, js-patched, and x86-only PPA binaries are covered by alternatives where practical |

## License

- Documentation (this guide and all Markdown files): [CC BY 4.0](LICENSE) - republish, translate, adapt freely, keep the attribution.
- Code under `tools/`: [MIT](tools/LICENSE).
