# omarchy-dragon-sl7

Omarchy on the Surface Laptop 7. The Snapdragon X Plus (X1P-64-100) model
comes first, with X Elite support where it is cheap to add. This project is a
thin overlay on upstream omacom/omarchy and omarchy-iso dragon branches. It
ships its own linux-sl7 kernel, and firmware is fetched at install time and
never redistributed.

## Status

Planning / pre-alpha. Nothing to install yet. See [PLAN.md](PLAN.md).

## Updating an existing install

For an Omarchy install on a Surface Laptop 7 that was not installed from our ISO. Download,
read, then run (`curl ... | bash` also works):

```
curl -fsSLO https://github.com/qBitnaut/omarchy-dragon-sl7/raw/main/tools/bootstrap/omarchy-sl7-bootstrap.sh
less omarchy-sl7-bootstrap.sh
bash omarchy-sl7-bootstrap.sh --dry-run    # read-only preview
bash omarchy-sl7-bootstrap.sh
```

It checks the machine, fetches the repository public key and requires its fingerprint to be
`6387C619EF246F6F20C536B72C3331C78353BA04` (embedded in the script), trusts it in pacman's
keyring, adds `Include = /etc/pacman.d/omarchy-sl7.conf` above `[core]`, installs
`omarchy-sl7-keyring omarchy-surface-sl7 linux-sl7 linux-sl7-headers iptsd-sl7` in one
`pacman -Syu` transaction through Omarchy's own wrapper (so the raw-pacman update guard is
satisfied), and runs `sl7-doctor`. Every step is idempotent. `--no-install` stops before the
transaction. From then on `omarchy update` carries our packages. Clean installs from our ISO
need none of this: the installer includes `omarchy-sl7-keyring` and `omarchy-surface-sl7`
enables the repository at first boot.

If a later Omarchy change drops the repository, `sudo omarchy-sl7-repo-ensure` puts it back
(it also runs after `omarchy`/`omarchy-settings` upgrades, at boot, and from an
`omarchy refresh pacman` hook). `sl7-doctor` reports the state.

## Repository

Packages are published as assets of the rolling GitHub Release `repo-aarch64`:

```
[omarchy-sl7]
SigLevel = Required DatabaseOptional
Server = https://github.com/qBitnaut/omarchy-dragon-sl7/releases/download/repo-aarch64
```

- `.github/workflows/publish-repo.yml` runs after linux-sl7, iptsd-sl7, omarchy-surface-sl7,
  omarchy-sl7-keyring and howdy-next succeed on main (and on manual dispatch). It takes their latest artifacts
  plus the packages already on the release, refuses firmware files, signs every package
  (`gpg --detach-sign`), runs `repo-add --sign`, keeps the current and previous version of each
  package, and replaces the assets. Concurrent runs queue.
- Releases cannot hold symlinks, so `omarchy-sl7.db` and `omarchy-sl7.files` are real copies of
  the `.tar.gz` files, each with a `.sig`. `omarchy-sl7.pub.asc` is the public key.
- pacman follows GitHub's redirect from `github.com/.../releases/download/...` to its object
  storage (libcurl follows redirects; the same scheme serves other Arch repositories).
- Signing uses the repository secrets `REPO_SIGNING_KEY` (ASCII-armored private key, no
  passphrase) and `REPO_SIGNING_KEY_ID`. Without them the workflow still runs and warns that
  the repository is unsigned. The key must match `pkgs/omarchy-sl7-keyring`; rotate with
  `tools/repo/make-keyring-files.sh`.
- Immutable releases must stay disabled for this repository.

## Firmware and licensing

Microsoft and Qualcomm firmware is never committed to or distributed from this
repository. It is fetched on the target machine from Microsoft's public
Surface Laptop 7 driver MSI. The .gitignore blocks firmware and captures.

## License

- Scripts and packaging are MIT licensed (see LICENSE).
- Kernel patches under pkgs/linux-sl7 (when added) are GPL-2.0, like the Linux kernel they modify.
- Microsoft/Qualcomm firmware is never included and remains under its own license.

## Credits

Built on the work of the community: omacom/omarchy dragon work,
denislopt/omarchy-surface-laptop7, bryce-hoehn/linux-surface-laptop-7,
ProgrammerIn-wonderland/ELLX-Kernel,
ItsLucas/surface-laptop-7-ubuntu-kernel, dwhinham/linux-sp11, and
linux-surface.
