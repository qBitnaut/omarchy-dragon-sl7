# omarchy-sl7-keyring

pacman keyring for the `omarchy-sl7` repository (same layout as `archlinuxarm-keyring`):

| file | content |
|---|---|
| `/usr/share/pacman/keyrings/omarchy-sl7.gpg` | the public signing key (binary or armored) |
| `/usr/share/pacman/keyrings/omarchy-sl7-trusted` | `FINGERPRINT:4:` per key that `pacman-key --populate` locally signs |
| `/usr/share/pacman/keyrings/omarchy-sl7-revoked` | fingerprints to remove (empty) |

`pacman-key --populate omarchy-sl7` runs from the `.install` script when the pacman keyring
exists; otherwise Omarchy's installer populates every keyring after `pacman-key --init`.

## Key

Fingerprint `6387C619EF246F6F20C536B72C3331C78353BA04` (Ed25519, "omarchy-dragon-sl7 package
signing"). The private half is the CI secret `REPO_SIGNING_KEY`. An empty `omarchy-sl7.gpg` /
`-trusted` makes the package build inert (no key files), which keeps `pacman-key --populate`
safe. Rotate with:

```
tools/repo/make-keyring-files.sh <FINGERPRINT> [GNUPGHOME | PUBKEY.asc]
# bump pkgrel in PKGBUILD, update the fingerprint in tools/bootstrap/omarchy-sl7-bootstrap.sh
```

Rotation: ship the new key in `omarchy-sl7.gpg` and `-trusted`, list the old fingerprint
in `-revoked`, and bump `pkgrel`.
