# PowerShell RPM Dependency Retrieval

Pure PowerShell tooling for building an offline, RHEL 9-compatible RPM bundle
from public rpm-md repositories. The script does not use Red Hat CDN,
`subscription-manager`, credentials, cookies, `dnf`, `repoquery`, `rpm`, or
`createrepo_c`.

The output is organized as a local DNF repository that can be transferred to an
airgapped environment:

```text
el9-rpm-bundle/
  packages/
  repodata/
  manifests/
  SHA256SUMS
```

## Basic Usage

Recommended default for RHEL 9 x86_64 work:

```powershell
.\rpm\Get-Rhel9RpmClosure.ps1 `
  -Package curl,wget,tar `
  -OutputDirectory .\el9-rpm-bundle
```

The default source is AlmaLinux 9 BaseOS, AppStream, and CRB. These track
EL9-compatible content for the major release. Rocky Linux and Oracle Linux
public repositories are also available:

```powershell
.\rpm\Get-Rhel9RpmClosure.ps1 `
  -Package curl,wget `
  -Provider RockyLinux `
  -OutputDirectory .\el9-rpm-bundle
```

Include weak dependencies when you want behavior closer to DNF's
`install_weak_deps=True`:

```powershell
.\rpm\Get-Rhel9RpmClosure.ps1 `
  -Package git `
  -IncludeWeakDependencies `
  -OutputDirectory .\el9-git
```

Use module streams explicitly for modular AppStream content:

```powershell
.\rpm\Get-Rhel9RpmClosure.ps1 `
  -Package nodejs,npm `
  -ModuleStream nodejs:20 `
  -OutputDirectory .\el9-nodejs20
```

You can also request a module profile:

```powershell
.\rpm\Get-Rhel9RpmClosure.ps1 `
  -ModuleProfile nodejs:20/common `
  -OutputDirectory .\el9-nodejs20-common
```

For EPEL-style packages, add:

```powershell
.\rpm\Get-Rhel9RpmClosure.ps1 `
  -Package jq `
  -IncludeEpel `
  -OutputDirectory .\el9-jq
```

`-IncludeEpel` uses Oracle's public OL9 Developer EPEL repository because it
currently exposes gzip XML metadata that the pure PowerShell implementation can
read. If your organization requires a different public mirror, pass it directly:

```powershell
.\rpm\Get-Rhel9RpmClosure.ps1 `
  -Package jq `
  -NoDefaultRepositories `
  -Repository baseos=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/ `
  -Repository appstream=https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/ `
  -Repository crb=https://repo.almalinux.org/almalinux/9/CRB/x86_64/os/ `
  -Repository epel=https://mirror.example.com/epel/9/Everything/x86_64/
```

## Airgapped Install

Copy the output directory to the target host, then point DNF at the generated
repo metadata:

```bash
sudo dnf -y \
  --disablerepo="*" \
  --repofrompath=local,file:///path/to/el9-rpm-bundle \
  --setopt=local.gpgcheck=0 \
  --setopt=local.repo_gpgcheck=0 \
  install curl wget tar
```

The generated `manifests/airgap-el9.repo` is a starting point for the target
host. Adjust its `baseurl=file:///...` path after placing the bundle on the
airgapped system.

## Validation VM

`rpm/lima-rocky96-x86_64.yaml` defines a disposable Rocky Linux 9.6 x86_64 VM for
local DNF validation when a real RHEL 9.6 VM is not available:

```bash
limactl start --name codex-rocky96-x86 --tty=false rpm/lima-rocky96-x86_64.yaml
limactl shell codex-rocky96-x86
```

The VM mounts this workspace at `/workspace`.

## Important Limits

- Exact Red Hat RPMs are not publicly downloadable without entitlement; this
  script intentionally uses public EL-compatible repositories.
- The resolver emulates the RPM metadata dependency closure. Final validation
  should still be done with DNF on a representative RHEL 9 host.
- The script streams primary metadata and skips very large kernel/modalias/kmod
  capability indexes by default. Add `-IncludeKernelCapabilities` when building
  bundles for kernel modules or kernel-adjacent packages.
- The script reads `.xml.gz` and `.yaml.gz` repo metadata. Pure PowerShell does
  not natively decompress xz, zstd, bzip2, or sqlite metadata, so use public
  mirrors that expose gzip XML metadata.
- `-SkipFilelists` avoids large filelists metadata when you only need regular
  capability-based dependencies. DNF validation is especially important with
  this option because file-path dependencies may be assumed from the baseline
  host.
- The script does not know the target host's installed RPM database. It assumes
  basic RHEL release capabilities by default to avoid downloading an Alma/Rocky
  release package for a RHEL host. Add `-AssumeInstalledCapability` values if
  your baseline image already provides other capabilities.
