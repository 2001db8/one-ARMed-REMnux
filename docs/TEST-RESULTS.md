# Test results

This document records what was tested and what the results establish. For installation commands and known workarounds, use the [README](../README.md).

The results apply to the recorded VM states. A pinned salt-states release does not freeze APT, PyPI, npm or upstream downloads, so a later run can differ. Successful installer states are not a measure of how many tools work fully.

## Latest complete installation and upgrade tests

The latest complete installation and upgrade tests ran on **2026-09-15** with REMnux salt-states **v2026.37.1** in dedicated mode. All three VMs used **Ubuntu 24.04.5 ARM64** with kernel **7.0.0-31** on VMware Fusion.

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

This closes validation of the new installation default. It does not test an upgrade of an existing PowerShell installation, which the script still leaves untouched. The complete REMnux test baseline remains the September runs above.

## Ghidra 12.1.4 validation on 2026-10-05

A focused test used a patched Ubuntu ARM64 VM with REMnux salt-states **v2026.37.1** installed and no prior fixup. Release overrides selected **Ghidra 12.1.4**, using `ghidra_12.1.4_PUBLIC_20260921.zip`.

The first fixup installed Ghidra at `/opt/ghidra_12.1.4_PUBLIC` and built the `linux_arm_64` native components successfully with the bundled Gradle wrapper. Both fixup runs had explicitly captured exit status 0 and reported zero failures and zero skipped actions. The second run reused the installation and native components without another download or build.

The operator confirmed the GUI analysis and decompiler smoke test on `/usr/bin/true`, an ARM64 ELF executable. Its SHA-256 was `a82c1b5fd392d72148d53992a860224ff3753cb2dc8909e9bdd1620e54ee1b88`. The captured GUI console log was empty, so the GUI result rests on the operator's confirmation rather than console output.

The archived script's SHA-256 was `de7e72dd08b8a15c6b9e48dff713f0d1fa8ba8976b47254bc7453920d02a5b2a`. It matched the repository script before promoting 12.1.4 to the default. The test exercised the existing override path. The later default change does not belong to that hash.

This validates installation, the native build, basic GUI analysis and decompilation, and repeat-run behavior. It does not cover every Ghidra feature or upgrading an existing Ghidra installation. The complete REMnux test baseline remains unchanged.

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

These measurements remain useful for comparison, but the 2026-09-15 runs above are the current tested baseline.

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
sudo cp /var/cache/cast/installer/logs/results.yaml results.yaml_v2026.37.1
sudo chown "$USER":"$USER" results.yaml_v2026.37.1
python3 tools/remnux-results-normalize.py results.yaml_v2026.37.1 \
  --format json -o v2026.37.1_failed-states.json
python3 tools/remnux-results-normalize.py old_failed-states.json --compare v2026.37.1_failed-states.json \
  --format markdown -o old_vs_v2026.37.1_failed-state-diff.md
```

The last command assumes `old_failed-states.json` was generated from the older run in the same way. Use a Python environment with PyYAML available.

The normalizer keeps only `result: false` states. It removes volatile fields such as `__run_num__`, `duration` and `start_time`, strips noisy one-off text, sorts dependent failures and separates them from direct failures. Use JSON for comparisons and Markdown for a readable report.

Detailed operator checklists and raw logs are kept locally under `remnux/`, which is excluded from Git. This document is the public summary. It does not require readers to have those local artifacts.
