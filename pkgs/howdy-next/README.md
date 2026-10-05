# howdy-next

[howdy-next](https://codeberg.org/nathawat/howdy-next) for Arch Linux ARM (aarch64):
a C++23 reimplementation of Howdy face authentication (CLI, PAM module, compare
process, setuid auth helper). It recognises faces with OpenCV DNN (YuNet detection,
SFace recognition); the two ONNX models come from the `howdy-next-models` package.

The PKGBUILD is based on the AUR package
[howdy-next](https://aur.archlinux.org/packages/howdy-next) by nathawat (AUR git
`554051d`, 2026-09-26) and keeps its build flags, `check()`, license handling and
polkit drop-in. Differences: `arch=('aarch64')`, a dependency on `howdy-next-models`
(no model download at install time), sha256 checksums, a setuid assertion in
`package()`, and a shorter `.install` message. Upstream is GPL-3.0-or-later (the
license text comes from Arch's `licenses` package); our packaging files are MIT.

## Pins

| | |
|---|---|
| Upstream | https://codeberg.org/nathawat/howdy-next |
| Release | `v3.4.2` (2026-09-26), `pkgver=3.4.2` |
| Tag object / commit | `5f44399f8a03c9f814bdf58f2a49e7f812ad2895` / `06f82530403fc3bc64da59016c3c25bf82532f8d` |
| Source | `https://codeberg.org/nathawat/howdy-next/archive/v3.4.2.tar.gz` |
| Tarball sha256 | `e2e3afabc3d6d3fd696ec0ab6a1f144b6254449216b390be579864a6fd26c50a` |
| Tarball b2sum (matches the AUR) | `7e891a8ad0e4b30cc85ea2e29b2dfa47e2e488245eaec26e77906fbab46234d2dc444a040451a68bfa16ad4009409c96784f003e58213f5a5c7bd74a63862494` |
| `polkit-agent-helper-howdy.conf` sha256 | `2283fc4684751caa41e87023755bba5c3468475b6ed632b13a4ac6e9c748c512` |

### Updating the pins

1. Pick the new tag (`git ls-remote https://codeberg.org/nathawat/howdy-next 'refs/tags/v*'`).
2. Set `pkgver`, reset `pkgrel=1`, update the tag and commit in the PKGBUILD comment.
3. `curl -fsSLO https://codeberg.org/nathawat/howdy-next/archive/vX.Y.Z.tar.gz`, then
   `sha256sum` it into `sha256sums`. Compare its b2sum with the AUR PKGBUILD as a
   cross-check.
4. Diff the new `howdy/include/model_assets/opencv_model_manifest.hpp` and
   `THIRD_PARTY_NOTICES.md` against the old tag. If a model URL or sha256 changed,
   update `pkgs/howdy-next-models` first (see its README) and keep `pkgver` in step.
5. Diff the AUR PKGBUILD and `polkit-agent-helper-howdy.conf` for new flags or
   dependencies.
6. `makepkg --printsrcinfo > .SRCINFO`, push; CI builds on aarch64.

## Build and tests

`build()` runs CMake with `-DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib
-DCMAKE_INSTALL_LIBEXECDIR=lib`. `check()` runs upstream's default `ctest` suite
(104 tests at v3.4.2: unit tests, install-layout and catalogue checks). It is
headless: no camera, no GUI. The privileged PAM/setuid end-to-end tests
(`HOWDY_ENABLE_PRIVILEGED_TESTS`) and the camera e2e preset are off by default
and are not run. The suite passed on an x86_64 build host; the aarch64 build only
happens in CI (`.github/workflows/howdy-next.yml`, which uses `ci-build.sh` in the
pinned `omarchy-pkg-builder` image and uploads both packages as the artifact
`howdy-next-aarch64`).

## Installed files

- `/usr/bin/howdy`: the CLI (`howdy config`, `add`, `test`, `clear`, `disable`, ...)
- `/usr/lib/security/pam_howdy.so`: the PAM module
- `/usr/lib/howdy/howdy-compare`: the compare process
- `/usr/lib/howdy/howdy-auth-helper`: the **setuid root** helper (see below)
- `/etc/howdy/config.ini`: configuration (mode 0640 root; in `backup=`, so edits
  survive upgrades as `.pacnew`)
- `/usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf`: sandbox
  relaxation for polkit's helper (below)
- `/usr/share/bash-completion/completions/howdy`, man pages `howdy(1)`,
  `howdy.ini(5)`, `pam_howdy(8)`, Thai catalogue
- `/usr/share/licenses/howdy-next/`: `THIRD_PARTY_NOTICES.md`, `YUNET-MIT.txt`,
  `SFACE-APACHE-2.0.txt`
- the (empty, shared with `howdy-next-models`) directory `/usr/share/howdy/models/`
  and, at runtime, per-user data in `/etc/howdy/models/<user>.dat` (0600, SFace
  embeddings only, no images, not encrypted at rest)

The package owns no file under `/etc/pam.d`, `/usr/lib/pam.d` or `/etc/security`.

## The setuid helper

`/usr/lib/howdy/howdy-auth-helper` is installed `root:root` mode `4755`. That is
upstream's default (`HOWDY_INSTALL_AUTH_HELPER_SETUID=ON`) and the only setuid or
setgid file in the package. Its job, per upstream, is to let PAM consumers that run
as the user (a lock screen, for example) verify a face without making the enrolled
models world-readable: the helper stages root-controlled copies under `/run/howdy`
(tmpfs) for the unprivileged caller. It is built with the same flags as the rest.

`package()` fails the build if anything other than that one file is setuid or
setgid, or if the helper has another mode. The CI workflow repeats the check on the
finished package. To drop the helper's privilege entirely you would have to rebuild
with `-DHOWDY_INSTALL_AUTH_HELPER_SETUID=OFF`, which breaks non-root PAM consumers;
we do not do that.

## polkit sandbox drop-in

polkit 127's `polkit-agent-helper@.service` runs with `PrivateDevices=yes` and a
strict device policy, so it cannot open the camera. The drop-in (from the AUR
package) sets `PrivateDevices=no`, `DeviceAllow=char-video4linux rw` and
`DeviceAllow=/dev/uinput rw`. The rest of the sandbox (`NoNewPrivileges`,
`ProtectSystem=strict`, `MemoryDenyWriteExecute`, ...) stays. Whether
`MemoryDenyWriteExecute` is compatible with OpenCV DNN on aarch64 is untested;
check `journalctl -u 'polkit-agent-helper@*'` if `pkexec` face auth fails.

## PAM notes (not applied by this package)

Nothing here edits PAM. The face-unlock setup app does that later, with backups.
For reference (research notes, `faceunlock-research.md` section 6):

- Before touching anything, open `sudo -i` in a second terminal and keep it open.
  Omarchy's root account usually has no password, so `su` will not rescue you.
- Back up each file (`cp -a /etc/pam.d/sudo /etc/pam.d/sudo.bak`), write atomically,
  and change one stack at a time: sudo, then polkit, then the lock screen.
- `/etc/pam.d/sudo`: `auth sufficient pam_howdy.so workaround=native`, before the
  `include system-auth`.
- `/etc/pam.d/polkit-1`: copy the vendor file from `/usr/lib/pam.d/polkit-1`, prepend
  `auth sufficient pam_howdy.so` (no workaround: `native-input` would inject Enter
  through `/dev/uinput` into whatever has focus).
- Do not add it to `system-local-login`, `login`, `sddm`, `su` or `sshd`.
- A face or fingerprint `sufficient` line sits above faillock's `preauth` in
  `system-auth`, so a face match bypasses a faillock lockout. Cap attempts in the UI.
- Kill switches: `sudo howdy disable 1`, or remove the `pam_howdy.so` lines.
  Debug with `journalctl -b -t pam_howdy`.
- The lid gates built into howdy and Omarchy read `/proc/acpi/button/lid`, which the
  SL7 does not have; the setup app adds its own logind-based gate.
