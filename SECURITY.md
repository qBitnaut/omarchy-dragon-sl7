# Security

## Reporting a problem

Please report vulnerabilities privately, not in a public issue: use
[GitHub private vulnerability reporting](https://github.com/qBitnaut/omarchy-dragon-sl7/security/advisories/new)
for this repository. Include what you found, how to reproduce it and the affected
package or script. You can expect a first reply within a few days. This is a hobby
project with a single maintainer; there is no bug bounty.

## Signing key

Packages, the pacman database and the installer ISO checksum are signed with one key:

```
6387C619EF246F6F20C536B72C3331C78353BA04
```

- The fingerprint is also in `tools/bootstrap/omarchy-sl7-bootstrap.sh`,
  `tools/installer-kit/make-install-usb.sh` and `pkgs/omarchy-sl7-keyring/omarchy-sl7-trusted`.
  A change to any of them without a matching change here is a red flag.
- The public key is `tools/repo/omarchy-sl7.pub.asc` and a copy is published as an asset of
  the `repo-aarch64` and `installer-latest` releases. Never trust a key file by what it
  says about itself: compare the fingerprint.
- Check an ISO by hand:
  `gpg --import omarchy-sl7.pub.asc && gpg --status-fd 1 --verify NAME.iso.sha256.sig NAME.iso.sha256`
  and require `VALIDSIG 6387C619EF246F6F20C536B72C3331C78353BA04`. On Windows use
  [Gpg4win](https://www.gpg4win.org).
- `tools/installer-kit/make-install-usb.sh` does this check itself and fails closed;
  `--insecure-skip-signature` exists for emergencies and prints a warning.

## Trust model

What you trust when you install from this project:

- **The maintainer** (GitHub account `qBitnaut`, two-factor authentication on) and the
  signing key above. The key is stored as a GitHub Actions secret, used only by the
  `release` environment (restricted to `main`), inside a container with no network and no
  capabilities, pinned to an image digest.
- **GitHub Actions** as the build host. Workflow actions are pinned to full commit SHAs,
  build containers to image digests, and Actions are limited to GitHub-owned and verified
  creators. Package builds run in a digest-pinned Arch Linux ARM builder image.
- **Upstreams**, reviewed and pinned by commit or checksum, never followed blindly:
  - Arch Linux ARM packages and the `omacom/omarchy-pkg-builder` image
  - the Linux kernel (kernel.org tarballs, checksummed) and
    [valeronm/sl7-mac](https://github.com/valeronm/sl7-mac) (Surface Laptop 7 patch series
    and device trees)
  - Omarchy (`basecamp/omarchy`, `omarchy-iso`, `omarchy-pkgs`), pinned in `upstream.lock`,
    (its qcom-firmware-extract and linux-aarch64-pkgbase-shim PKGBUILDs are built from source)
  - [nate8199/omarchy-plugin-howdy-face](https://github.com/nate8199/omarchy-plugin-howdy-face)
    and Howdy (face unlock) and the YuNet / SFace models
  - libcamera (`git.libcamera.org`, pinned to a commit), iptsd
- **Not trusted:** the files on the release are only as good as the signature check. The
  ISO contains no Microsoft or Qualcomm firmware; it is extracted on your machine from
  Microsoft's own public driver package.

Out of scope: a compromised maintainer account or GitHub itself (a signature made by the CI
key would still verify), and the security of the upstream projects listed above.
