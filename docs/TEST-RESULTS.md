# Test results

This document records what was tested and what the results establish. For installation commands and known workarounds, use the [README](../README.md).

The results apply to the recorded VM states. A pinned salt-states release does not freeze APT, PyPI, npm or upstream downloads, so a later run can differ. Successful installer states are not a measure of how many tools work fully.

## Latest complete installation and upgrade tests

The latest complete installation and upgrade tests ran on **2026-10-07** with REMnux salt-states **v2026.41.2** in dedicated mode on VMware Fusion. Both VMs used **Ubuntu 24.04.5 ARM64**. The fresh VM ran kernel **7.0.0-38**, and the upgrade VM ran **7.0.0-31**.

| Scenario | Successful states | Failed states | Failure breakdown |
|---|---|---|---|
| Fresh installation | 997 / 1022 | 25 | 3 direct failures, 22 dependent failures |
| Upgrade from repaired v2026.37.1 | 993 / 1018 | 25 | 3 direct failures, 22 dependent failures |

These are installer results before fixup. Both installers exited 1 and had exactly the same failed state IDs. Both runs include 17 successful ARM64 skip notifications, which do not represent installed tools. No new failed state IDs appeared relative to the September fresh baseline.

Four additional one-time GRUB cleanup states account for the larger fresh-install total. They check for the legacy `nomodeset` parameter, regenerate GRUB configuration only if it changes, and create the marker directory and file `/var/lib/remnux/nomodeset-cleaned`. In the fresh run, no GRUB configuration change was needed and `update-grub` did not run. Only the directory and marker file were created. The marker prevents these four states from being included on later runs, so the count difference does not represent additional installed tools.

### Upstream improvements and remaining failures

The release includes upstream ARM64 installation paths for PowerShell, FLOSS, Qiling/Keystone and Vivisect without its GUI. PowerShell 7.6.6 and FLOSS 3.1.1 were installed in both scenarios. Qiling 1.4.6, Keystone 0.9.2 and Vivisect 1.3.2 were installed on the fresh VM and reused on the upgrade VM.

Eight pre-fixup checks passed in each VM. They covered PowerShell command execution, FLOSS native string extraction and CLI help, Qiling/Keystone imports and x86 `nop` assembly, Vivisect import, JStillery processing, and the Magika Python client's version and classification of `/etc/os-release`. Magika was invoked by its full path because its Python-client command link was missing in both VMs.

The installer also reports successful ARM64 installation states for capa, Docker Compose, YARA-X, PolarProxy and 7-Zip. Previously failing packages including libemu, libemu-dev, msoffice-crypt, PortEx, Android Project Creator, InspIRCd, signsrch, EvilClippy, ilspycmd, Burp Suite Community, JD-GUI and baksmali also report success. These tools did not receive individual runtime smoke tests in this run.

Three direct failures remain.

- Ghidra is still requested as an unavailable APT package. Its dependent configuration and GhidrAssist-MCP states also fail.
- Detect It Easy still downloads an amd64 package whose amd64 Qt dependencies cannot be satisfied.
- peframe-ds still fails while building its obsolete `readline` dependency.

Fixup does not rerun Salt or clear these recorded installer failures. Its Ghidra installation does not establish that the dependent Salt configuration, GhidrAssist-MCP or dependent OpenCode configuration has been completed.

### Fixup, source checks and corrected smoke tests

Both VMs completed two fixup runs with captured exit status 0 and no reported failures or skipped actions. Fresh fixup installed Ghidra 12.1.4 and built its ARM64 native components. Upgrade fixup reused the existing Ghidra installation. Both exposed the Magika Python client and left upstream FLOSS under `/opt/flare-floss` unchanged. Neither second run repeated tool installation, native builds or upstream tool downloads. APT index refreshes still ran as intended.

The first post-fixup smoke blocks used the obsolete `/opt/floss` paths. Those two checks exited 127 in both VMs, while the other six checks passed. The original failed logs were retained. Separate corrective checks verified the link to `/opt/flare-floss/bin/floss`, native string extraction and CLI help, all with exit 0 in both VMs. This was a correction to the test commands, not a repair of FLOSS.

APT refresh succeeded before installation, after installation and after fixup. All captured Ubuntu base package indexes remained ARM64-only, all four Noble suites were present, and `libc6:amd64` had no candidate. The fresh installer consolidated the Ubuntu source stanzas while retaining the explicit ARM64 restriction. It did not register i386. The upgrade retained an existing i386 registration until fixup removed it as unused.

The post-fixup Ghidra check established the presence of an executable ARM64 decompiler. It was not a new GUI test. The separate October 5 GUI test is recorded below. Magika's CPU-vendor warning on the upgrade VM did not prevent classification. These checks do not establish complete support for every REMnux tool.

### Tested script revision

Both runs archived the revised script as `one-armed-remnux-fixup-upstream-floss.sh`. Its SHA-256 is `4398a5b0d75093949e2e9e40a5bf2b84d02167a29a9396ab44a452b2d3ea25a6`. All three archived copies matched the repository script at review time. The logs show the upstream-FLOSS branch, but do not record the executed script filename or an execution-time hash. The original script and hash files remain separate artifacts.

The tested script still named v2026.37.1 as its compatibility baseline. Promotion changes that constant to v2026.41.2 without changing the tested installation logic. The archived hash above therefore identifies the pre-promotion script. The local mocked test suite covers the baseline update as well as preservation of upstream and legacy FLOSS installations.

All 29 local control-flow tests passed after promotion. Bash syntax validation and `git diff --check` also passed. These mocked tests do not install packages or replace the VM checks above.

## Previous baseline on 2026-09-15

These installation and upgrade tests used REMnux salt-states **v2026.37.1** in dedicated mode. All three VMs used **Ubuntu 24.04.5 ARM64** with kernel **7.0.0-31** on VMware Fusion.

| Scenario | Successful states | Failed states | Failure breakdown |
|---|---|---|---|
| Fresh installation | 980 / 1071 | 91 | 39 direct failures, 52 dependent failures |
| Upgrade from repaired v2026.34.3 | 981 / 1067 | 86 | 37 direct failures, 49 dependent failures |
| Direct upgrade from v2026.27.8 | 981 / 1067 | 86 | 37 direct failures, 49 dependent failures |

These counts come from the installer, before fixup. Every scenario then completed two fixup runs with exit 0 and no reported failures or skipped actions. The second runs did not repeat tool installations, native builds or upstream downloads. All eight focused smoke tests passed in each scenario.

### Source preparation

Every active Ubuntu base stanza contained `Architectures: arm64` before installation. The source archives show that this restriction survived all three installer runs.

APT refresh succeeded while i386 was still registered. Ubuntu package indexes remained ARM64-only and `libc6:amd64` had no candidate. Fixup later removed unused i386 as cleanup. It was not needed to restore APT health. All final APT checks passed too.

The fresh install and the upgrade from v2026.34.3 each had 20 fewer failed states than their counterparts from the previous day. No new state IDs failed. The recovered states included i386 registration with APT refresh, Node.js installation and dependent npm and configuration steps.

This is why the source restriction is part of preparation for a fresh VM, not just a repair after a failed install. It avoids dependent failures without making unavailable x86 packages compatible with ARM64.

### Upgrade differences

Both upgrades had five fewer failures than the fresh install. Qiling, Vivisect and their command links were already installed. This does not establish that the Vivisect GUI works. Four one-time GRUB states were absent from the upgrades, which accounts for the smaller total number of states.

The direct upgrade from v2026.27.8 had exactly the same failed state IDs as the upgrade from v2026.34.3. Its first fixup installed FLOSS 3.1.1 and retained PowerShell 7.6.1. Qiling was already functional in an environment using pip 26.1.2. Its capability probe reported `default-isolation-only`, but no Keystone rebuild was needed. This tests preservation of that environment, not a new build with default isolation.

The older-baseline run is evidence for that particular starting state. It is not a guarantee that every older REMnux installation will upgrade in the same way.

### Tool checks

The fresh fixup built Ghidra 12.1.2 ARM64 native components and Qiling/Keystone. It installed PowerShell 7.6.3 and FLOSS 3.1.1. The upgrade runs reused working installations where possible.

| Check | What passed |
|---|---|
| PowerShell | Version command |
| Qiling and Keystone | Imports and assembly of an x86 `nop` |
| FLOSS native extension | String extraction through `binary2strings` |
| FLOSS CLI | Help command |
| JStillery | Processing a small JavaScript input |
| Magika version | Python client version command |
| Magika classification | Classification of `/etc/os-release` |
| Ghidra native component | Presence of an executable ARM64 decompiler binary |

Magika 1.0.3 used model `standard_v3_3`. ONNX Runtime printed an unknown-CPU-vendor warning on the upgrade VMs, but classification still succeeded.

These are focused checks. They do not cover the full Ghidra GUI, every FLOSS analysis mode or every REMnux tool. The known Wine, STPyV8, PyQt5 and x86-package limitations remain. See the [README's tool alternatives](../README.md#step-5---probably-not-worth-fixing-imho-and-what-to-use-instead).

### Script revision and local checks

All three runs used the same fixup script. Its SHA-256 was `604279a137f6b95066d5c69beeeef91c2ee442a29b5cb5705d60edc61910380a`.

The subsequent PowerShell and Ghidra default changes are not part of that hash or those VM results. Their focused validation is recorded below. Archived logs and scripts were kept unchanged.

At the VM-test review, all 21 local control-flow tests passed. A version-selection test was added with the PowerShell change, bringing the passing total to 22. These tests use temporary fixtures and mocked system commands. They check error handling without installing packages or making network requests. Deliberate APT and download failures were not induced on the accepted VMs.

### Historical package gaps

The September guide listed the following package failures and alternatives. They are retained here for older installations, not as failures of the current baseline. Their installation states succeed in the October fresh run, without individual runtime validation.

| Tool/package | Earlier gap or alternative |
|---|---|
| libemu / libemu-dev | Packages unavailable. Speakeasy or Qiling cover shellcode-emulation workflows, but are not drop-in libraries. |
| msoffice-crypt | Package unavailable. msoffcrypto-tool covers supported encrypted Office documents. |
| PortEx | Package unavailable. Ghidra, pefile or readpe cover PE inspection. |
| Android Project Creator | Package unavailable. apktool or jadx cover APK inspection. |
| InspIRCd | The state downloaded an amd64 package. The newer ARM64 state uses Ubuntu's package. |
| signsrch | YARA rules or binwalk were suggested alternatives. |
| EvilClippy / ilspycmd | ARM64 .NET builds or installation were suggested instead of the failing package path. |
| Burp Suite Community | The upstream Linux ARM64 installer was suggested. |
| JD-GUI and baksmali | Running the upstream Java archives was suggested. |

## PowerShell 7.6.6 validation on 2026-10-05

After the September runs, the script's PowerShell default changed from **7.6.3 to 7.6.6**. A focused test on an Ubuntu ARM64 VM with salt-states **v2026.37.1** verified installation from the [Microsoft Linux ARM64 tarball](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6).

The first fixup installed PowerShell 7.6.6 and its version command succeeded. The second fixup detected the existing installation and did not download or install it again. Both fixup summaries reported zero failures, zero skipped actions and exit 0.

The noninteractive smoke test also passed.

```bash
pwsh -NoLogo -NoProfile -NonInteractive \
  -Command '"REMNUX_PWSH_SMOKE_TEST"; $PSVersionTable.PSVersion.ToString()'
printf 'PowerShell exit status: %s\n' "$?"
```

```text
REMNUX_PWSH_SMOKE_TEST
7.6.6
PowerShell exit status: 0
```

This closed validation of the new installation default. It did not test an upgrade of an existing PowerShell installation, which the fixup script leaves untouched. At the time, the complete REMnux baseline remained the September runs.

## Ghidra 12.1.4 validation on 2026-10-05

A focused test used a patched Ubuntu ARM64 VM with REMnux salt-states **v2026.37.1** installed and no prior fixup. Release overrides selected **Ghidra 12.1.4**, using `ghidra_12.1.4_PUBLIC_20260921.zip`.

The first fixup installed Ghidra at `/opt/ghidra_12.1.4_PUBLIC` and built the `linux_arm_64` native components successfully with the bundled Gradle wrapper. Both fixup runs had explicitly captured exit status 0 and reported zero failures and zero skipped actions. The second run reused the installation and native components without another download or build.

The operator confirmed the GUI analysis and decompiler smoke test on `/usr/bin/true`, an ARM64 ELF executable. Its SHA-256 was `a82c1b5fd392d72148d53992a860224ff3753cb2dc8909e9bdd1620e54ee1b88`. The captured GUI console log was empty, so the GUI result rests on the operator's confirmation rather than console output.

The archived script's SHA-256 was `de7e72dd08b8a15c6b9e48dff713f0d1fa8ba8976b47254bc7453920d02a5b2a`. It matched the repository script before promoting 12.1.4 to the default. The test exercised the existing override path. The later default change does not belong to that hash.

This validates installation, the native build, basic GUI analysis and decompilation, and repeat-run behavior. It does not cover every Ghidra feature or upgrading an existing Ghidra installation. This focused test did not change the complete REMnux baseline at the time.

## Earlier tests

### Dedicated runs on 2026-09-14

These runs used salt-states v2026.37.1 before the explicit per-stanza source preparation and revised script error handling.

| Scenario | Successful states | Failed states | Failure breakdown |
|---|---|---|---|
| Fresh installation | 960 / 1071 | 111 | 39 direct failures, 72 dependent failures |
| Upgrade from repaired v2026.34.3 | 961 / 1067 | 106 | 37 direct failures, 69 dependent failures |

Neither run introduced newly failed states relative to its comparison baseline. The fresh run was compared with v2026.34.3, and the upgrade with the fresh v2026.37.1 run. Qiling, Vivisect and their links accounted for the five fewer upgrade failures. Four one-time GRUB states were absent from the upgrade.

Both installers encountered the i386 registration and Ubuntu Ports index failure. Fixup removed unused i386 and restored successful APT refresh. Both fixup runs in each scenario exited 0 and all 11 sections reported OK. Repeat runs did not reinstall tools, rebuild natives or repeat downloads. JStillery processing and Magika classification passed.

The fresh path also verified the Ghidra 12.1.2 ARM64 native build and the Keystone workaround with pip 26.2.1. The upgrade was repeated after updating Ubuntu to 24.04.5 and rebooting into kernel 7.0.0-31. The failed state set and successful fixup results were unchanged.

These measurements remain useful for comparison. They were superseded by the September 15 tests and then the October 7 baseline above.

### Earlier tool investigations

- Earlier addon-mode runs showed the same broad package and tool failure classes. Addon mode omits some dedicated desktop configuration, so its state counts are not directly comparable.
- A GitHub HTTP 429 response while downloading `pdfid.ini` caused dependent failures in an earlier run. They disappeared on retry. This was a temporary download problem, unlike the recurring architecture and packaging limitations.
- Keystone builds under pip 26.2.1 failed with missing standard-library modules such as `__future__` and `traceback` in the bundled LLVM Python helper. This reproduced the build-isolation issue previously seen with v2026.34.3. Standard-venv isolation produced a working native build, verified by imports and x86 `nop` assembly.
- FLOSS 3.1.1 was also tested separately with Python 3.12 against a 32-bit x86 Wine `makecab.exe`. Static extraction returned 1,446 strings. Stack, tight and decoded-string analysis completed with exit 0 but returned no strings for that file. This proves those paths ran, not that they recovered obfuscated strings from a known-positive sample.
- The manual peframe-ds installation worked after bypassing its obsolete `readline` dependency. That observation does not remove the risks of `--no-deps`, so the workaround remains outside the automated script.

## Comparing installer runs

`remnux results` is useful for a first look. `remnux-diag.py` groups root causes and dependent failures for a single run. For repeatable comparisons, [tools/remnux-results-normalize.py](../tools/remnux-results-normalize.py) produces a failed-state report without volatile timestamps and run numbers.

Run the following from the repository root in an environment that can read the installer logs. The example assumes the repository is available inside the VM. If it is only on the host, copy the results there first and run the normalizer against that copy. Keep each run's YAML under a distinct name and do not overwrite old reports.

```bash
python3 -m pip install pyyaml
sudo cp /var/cache/cast/installer/logs/results.yaml results.yaml_v2026.41.2
sudo chown "$USER":"$USER" results.yaml_v2026.41.2
python3 tools/remnux-results-normalize.py results.yaml_v2026.41.2 \
  --format json -o v2026.41.2_failed-states.json
python3 tools/remnux-results-normalize.py old_failed-states.json --compare v2026.41.2_failed-states.json \
  --format markdown -o old_vs_v2026.41.2_failed-state-diff.md
```

The last command assumes `old_failed-states.json` was generated from the older run in the same way. Use a Python environment with PyYAML available.

The normalizer keeps only `result: false` states. It removes volatile fields such as `__run_num__`, `duration` and `start_time`, strips noisy one-off text, sorts dependent failures and separates them from direct failures. Use JSON for comparisons and Markdown for a readable report.

Detailed operator checklists and raw logs are kept locally under `remnux/`, which is excluded from Git. This document is the public summary. It does not require readers to have those local artifacts.
