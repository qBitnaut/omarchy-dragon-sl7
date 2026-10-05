# howdy-next-models

The two ONNX models [howdy-next](../howdy-next) needs, packaged so that nothing is
downloaded at install time (a fresh install stays offline-reproducible and no root
`curl` is needed). `howdy-next` depends on this package. `howdy download-models`
still works if you want upstream's own copy.

`arch=('any')`: the files are data. They are fetched from OpenCV Zoo at exact commits
(not branches) and verified by sha256 on every build.

## Pins

The URLs, revisions and hashes are the ones howdy-next v3.4.2 pins in
`howdy/include/model_assets/opencv_model_manifest.hpp` and `THIRD_PARTY_NOTICES.md`.
`pkgver` follows the howdy-next release whose manifest it mirrors.

| File | OpenCV Zoo revision | Size | sha256 | License |
|---|---|---|---|---|
| `face_detection_yunet_2026may.onnx` (YuNet) | `26cc381e4d2594bb9f47a26eb8fd96c94a13660d` | 229,738 B | `ebafce4e3c118d6554634be5c27ab333b4c047a9a8c3faf1d7cf93101c22f0f0` | MIT, (c) 2020 Shiqi Yu |
| `face_recognition_sface_2021dec_int8.onnx` (SFace, int8) | `088c3571ec70df15100a5e4c26894d95951e92e9` | 9,896,933 B | `2b0e941e6f16cc048c20aee0c8e31f569118f65d702914540f7bfdc14048d78a` | Apache-2.0 |

Sources (the `raw` form; `raw.githubusercontent.com` serves Git LFS pointer files for
these models, so do not use it):

```
https://github.com/opencv/opencv_zoo/raw/<rev>/models/face_detection_yunet/face_detection_yunet_2026may.onnx
https://github.com/opencv/opencv_zoo/raw/<rev>/models/face_recognition_sface/face_recognition_sface_2021dec_int8.onnx
```

License texts, from the same revisions (`models/<name>/LICENSE`):

| File | sha256 |
|---|---|
| `YUNET-MIT.txt` | `c83b8120c50ccbd4c4f96edf53141bdd566ebb8f8e9227e415326aa1b1aba958` |
| `SFACE-APACHE-2.0.txt` | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |

The SFace revision has no extra `NOTICE` file (per upstream's notices). Both licenses
allow redistribution with the notice, which is why the texts are installed.

## Installed files

- `/usr/share/howdy/models/face_detection_yunet_2026may.onnx` (0644 root)
- `/usr/share/howdy/models/face_recognition_sface_2021dec_int8.onnx` (0644 root)
- `/usr/share/licenses/howdy-next-models/YUNET-MIT.txt`
- `/usr/share/licenses/howdy-next-models/SFACE-APACHE-2.0.txt`

`/usr/share/howdy/models/` is `HOWDY_MODELS_DIR`, howdy-next's compiled-in default for
`CMAKE_INSTALL_PREFIX=/usr`. howdy-next installs that directory empty; both packages
own the directory, neither owns the other's files.

## Updating the pins

1. When a new howdy-next release changes the manifest, diff
   `howdy/include/model_assets/opencv_model_manifest.hpp` between the tags.
2. Update `_yunet_rev`, `_sface_rev`, `_yunet_model`, `_sface_model` in the PKGBUILD.
3. Download each model from the `raw` URL above and `sha256sum` it. It must equal the
   `.sha256` in the manifest (and the size must match `.size`); put it in
   `sha256sums`. Do the same for the two LICENSE files at the new revisions.
4. Set `pkgver` to the howdy-next version, `pkgrel=1`, regenerate with
   `makepkg --printsrcinfo > .SRCINFO`.
5. Never point at a branch name: the pin must stay an immutable commit.
