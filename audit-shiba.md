# GrapheneOS Supply Chain Audit

- **Device:** `shiba`
- **Tag:** `2026042100`
- **Build root:** `/home/guix/grapheneos`
- **Generated:** 2026-05-12T17:01:30+00:00
- **Tool:** `audit-supply-chain.py`

## Summary

| State | Meaning | Count |
|---|---|---|
| ✓ | verified (hash/sig ตรง expected) | 3 |
| ✗ | mismatch / fail | 0 |
| ? | computed hash, ไม่มี expected เทียบ | 17 |
| · | informational (group/metadata) | 55 |

## Tree

```
· GrapheneOS Supply Chain Audit (shiba, tag 2026042100)
  • generated: 2026-05-12T16:58:51+00:00
├── · Guix packages (guix-manifest.scm)
│     source: /home/guix/grapheneos/guix-manifest.scm
│     • total packages: 49
│     • source: Guix official channel (gnu/packages/*.scm)
│     • verification: content-addressed store + signed substitutes
│   ├── · bash
│   │     source: guix-pkg:bash
│   │     • recipe: gnu/packages/bash.scm:161:4
│   │     • version: 5.2.37
│   ├── · bc
│   │     source: guix-pkg:bc
│   │     • recipe: gnu/packages/algebra.scm:734:2
│   │     • version: 1.08.2
│   ├── · binutils
│   │     source: guix-pkg:binutils
│   │     • recipe: gnu/packages/base.scm:764:2
│   │     • version: 2.33.1
│   ├── · bison
│   │     source: guix-pkg:bison
│   │     • recipe: gnu/packages/bison.scm:78:2
│   │     • version: 3.0.5
│   ├── · ccache
│   │     source: guix-pkg:ccache
│   │     • recipe: gnu/packages/ccache.scm:36:2
│   │     • version: 4.8.3
│   ├── · coreutils
│   │     source: guix-pkg:coreutils
│   │     • recipe: gnu/packages/base.scm:471:2
│   │     • version: 9.1
│   ├── · curl
│   │     source: guix-pkg:curl
│   │     • recipe: gnu/packages/curl.scm:69:2
│   │     • version: 8.6.0
│   ├── · diffutils
│   │     source: guix-pkg:diffutils
│   │     • recipe: gnu/packages/base.scm:363:2
│   │     • version: 3.12
│   ├── · findutils
│   │     source: guix-pkg:findutils
│   │     • recipe: gnu/packages/base.scm:423:2
│   │     • version: 4.10.0
│   ├── · flex
│   │     source: guix-pkg:flex
│   │     • recipe: gnu/packages/flex.scm:35:2
│   │     • version: 2.6.4
│   ├── · fontconfig
│   │     source: guix-pkg:fontconfig
│   │     • recipe: gnu/packages/fontutils.scm:1485:2
│   │     • version: 2.14.0
│   ├── · freetype
│   │     source: guix-pkg:freetype
│   │     • recipe: gnu/packages/fontutils.scm:103:2
│   │     • version: 2.13.3
│   ├── · gawk
│   │     source: guix-pkg:gawk
│   │     • recipe: gnu/packages/gawk.scm:41:2
│   │     • version: 5.3.0
│   ├── · gcc-toolchain@14
│   │     source: guix-pkg:gcc-toolchain
│   │     • recipe: gnu/packages/commencement.scm:3643:4
│   │     • version: 9.5.0
│   ├── · git
│   │     source: guix-pkg:git
│   │     • recipe: gnu/packages/version-control.scm:596:2
│   │     • version: 2.52.0
│   ├── · git-lfs
│   │     source: guix-pkg:git-lfs
│   │     • recipe: gnu/packages/version-control.scm:4100:2
│   │     • version: 3.7.0
│   ├── · glibc-locales
│   │     source: guix-pkg:glibc-locales
│   │     • recipe: gnu/packages/base.scm:1380:2
│   │     • version: 2.41
│   ├── · gnupg
│   │     source: guix-pkg:gnupg
│   │     • recipe: gnu/packages/gnupg.scm:413:2
│   │     • version: 1.4.23
│   ├── · gperf
│   │     source: guix-pkg:gperf
│   │     • recipe: gnu/packages/gperf.scm:26:2
│   │     • version: 3.3
│   ├── · grep
│   │     source: guix-pkg:grep
│   │     • recipe: gnu/packages/base.scm:120:2
│   │     • version: 3.11
│   ├── · gzip
│   │     source: guix-pkg:gzip
│   │     • recipe: gnu/packages/compression.scm:272:2
│   │     • version: 1.14
│   ├── · imagemagick
│   │     source: guix-pkg:imagemagick
│   │     • recipe: gnu/packages/imagemagick.scm:139:2
│   │     • version: 6.9.13-5
│   ├── · inetutils
│   │     source: guix-pkg:inetutils
│   │     • recipe: gnu/packages/admin.scm:1291:2
│   │     • version: 2.5
│   ├── · jq
│   │     source: guix-pkg:jq
│   │     • recipe: gnu/packages/web.scm:5764:2
│   │     • version: 1.8.1
│   ├── · libelf
│   │     source: guix-pkg:libelf
│   │     • recipe: gnu/packages/elf.scm:263:2
│   │     • version: 0.8.13
│   ├── · libxml2
│   │     source: guix-pkg:libxml2
│   │     • recipe: gnu/packages/xml.scm:194:2
│   │     • version: 2.14.6
│   ├── · libxslt
│   │     source: guix-pkg:libxslt
│   │     • recipe: gnu/packages/xml.scm:343:2
│   │     • version: 1.1.43
│   ├── · lz4
│   │     source: guix-pkg:lz4
│   │     • recipe: gnu/packages/compression.scm:1041:2
│   │     • version: 1.10.0
│   ├── · lzop
│   │     source: guix-pkg:lzop
│   │     • recipe: gnu/packages/compression.scm:698:2
│   │     • version: 1.04
│   ├── · make
│   │     source: guix-pkg:make
│   │     • recipe: gnu/packages/base.scm:678:2
│   │     • version: 4.2.1
│   ├── · node
│   │     source: guix-pkg:node
│   │     • recipe: gnu/packages/node.scm:748:2
│   │     • version: 22.14.0
│   ├── · nss-certs
│   │     source: guix-pkg:nss-certs
│   │     • recipe: gnu/packages/nss.scm:318:2
│   │     • version: 3.101.4
│   ├── · openjdk@21:jdk
│   │     source: guix-pkg:openjdk
│   │     • recipe: gnu/packages/java.scm:1834:2
│   │     • version: 22.0.2
│   ├── · openssl
│   │     source: guix-pkg:openssl
│   │     • recipe: gnu/packages/tls.scm:449:2
│   │     • version: 1.1.1u
│   ├── · patchelf
│   │     source: guix-pkg:patchelf
│   │     • recipe: gnu/packages/elf.scm:328:2
│   │     • version: 0.18.0
│   ├── · pngcrush
│   │     source: guix-pkg:pngcrush
│   │     • recipe: gnu/packages/image.scm:387:2
│   │     • version: 1.8.13
│   ├── · procps
│   │     source: guix-pkg:procps
│   │     • recipe: gnu/packages/linux.scm:3543:2
│   │     • version: 4.0.3
│   ├── · python
│   │     source: guix-pkg:python
│   │     • recipe: gnu/packages/python.scm:680:2
│   │     • version: 3.11.14
│   ├── · python-wrapper
│   │     source: guix-pkg:python-wrapper
│   │     • recipe: gnu/packages/python.scm:1523:2
│   │     • version: 3.11.14
│   ├── · rsync
│   │     source: guix-pkg:rsync
│   │     • recipe: gnu/packages/rsync.scm:41:2
│   │     • version: 3.4.1
│   ├── · sed
│   │     source: guix-pkg:sed
│   │     • recipe: gnu/packages/base.scm:196:2
│   │     • version: 4.9
│   ├── · squashfs-tools
│   │     source: guix-pkg:squashfs-tools
│   │     • recipe: gnu/packages/compression.scm:1091:2
│   │     • version: 4.6.1
│   ├── · tar
│   │     source: guix-pkg:tar
│   │     • recipe: gnu/packages/base.scm:235:2
│   │     • version: 1.35
│   ├── · unzip
│   │     source: guix-pkg:unzip
│   │     • recipe: gnu/packages/compression.scm:1985:2
│   │     • version: 6.0
│   ├── · util-linux
│   │     source: guix-pkg:util-linux
│   │     • recipe: gnu/packages/linux.scm:3188:2
│   │     • version: 2.40.4
│   ├── · which
│   │     source: guix-pkg:which
│   │     • recipe: gnu/packages/base.scm:1540:2
│   │     • version: 2.21
│   ├── · xz
│   │     source: guix-pkg:xz
│   │     • recipe: gnu/packages/compression.scm:552:2
│   │     • version: 5.4.5
│   ├── · zip
│   │     source: guix-pkg:zip
│   │     • recipe: gnu/packages/compression.scm:1941:2
│   │     • version: 3.0
│   └── · zlib
│         source: guix-pkg:zlib
│         • recipe: gnu/packages/compression.scm:113:2
│         • version: 1.3.1
├── ✓ repo (Google Git tool)
│     source: https://storage.googleapis.com/git-repo-downloads/repo
│     sha256: 11bc6893e9e0c0940fc1cc95b75c645f9a29fca879d89ceaa898a4d761a2add7
│     • local: /home/guix/.bin/repo
│     • hash ตรงกับ known-good
├── ✓ GrapheneOS source tag 2026042100
│     source: https://github.com/GrapheneOS/platform_manifest.git
│     ssh-fingerprint: SHA256:AhgHif0mei+9aNyKLfMZBh2yptHdw/aN7Tlh/j2eFwM
│     expected: SHA256:AhgHif0mei+9aNyKLfMZBh2yptHdw/aN7Tlh/j2eFwM
│     • SSH fingerprint: SHA256:AhgHif0mei+9aNyKLfMZBh2yptHdw/aN7Tlh/j2eFwM
├── · Vendor blobs (adevtool → dl.google.com)
│     source: https://dl.google.com/dl/android/aosp/
│   ├── ? shiba-bp4a.260205.001-factory-35b8480d.zip
│   │     source: dl.google.com/dl/android/aosp/shiba/
│   │     sha256: 35b8480d70480bbef52e99837f18beb539a8894807d1b02696f206d035c70282
│   │     • size: 3,734,882,904 bytes
│   └── ? shiba-cp1a.260405.005-factory-f88d5199.zip
│         source: dl.google.com/dl/android/aosp/shiba/
│         sha256: f88d5199ff51e3ac4e502a08d0a6f82a32b4ba68009982c3a6e4d5b69ce1f950
│         • size: 3,781,948,650 bytes
├── ✓ adevtool yarn.lock
│     source: registry.yarnpkg.com
│     sha256 (yarn.lock content): d33f86ba01f3fd5b14087d59f079f1ac2122652d63059f399f390e67c8b7fa7d
│     • yarn.lock path: vendor/adevtool/yarn.lock
│     • package entries: 619
│     • with integrity hash: 634
├── · Signing keys (shiba)
│     source: locally generated via patch-grapheneos.sh
│   ├── ? bluetooth.x509.pem
│   │     source: keys/shiba/bluetooth.x509.pem
│   │     sha256 (x509 fingerprint): a370e003c923b18d11780417903027a7688486bac7c5c6b9f10397350c7a89d4
│   │     • expires: Sep 26 18:42:39 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? gmscompat_lib.x509.pem
│   │     source: keys/shiba/gmscompat_lib.x509.pem
│   │     sha256 (x509 fingerprint): 1d488da4967677cdba525f9c8d7f0b9808ae485174b117787e1c3d3c0f9184e1
│   │     • expires: Sep 26 18:42:40 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? media.x509.pem
│   │     source: keys/shiba/media.x509.pem
│   │     sha256 (x509 fingerprint): cfe4cfdf0bf97c1146cad411c360fbf042c32572ee0e653300e81dda948e17e4
│   │     • expires: Sep 26 18:42:41 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? networkstack.x509.pem
│   │     source: keys/shiba/networkstack.x509.pem
│   │     sha256 (x509 fingerprint): e700cdc6118c490488d24da853c43394d526bc93ab06e08e9faaa1675d7a4605
│   │     • expires: Sep 26 18:42:41 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? nfc.x509.pem
│   │     source: keys/shiba/nfc.x509.pem
│   │     sha256 (x509 fingerprint): ba0d433f460a80cf9bffc3af8a00936a6f759225d5ce27d6a2d6e4727c378e50
│   │     • expires: Sep 26 18:42:43 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? platform.x509.pem
│   │     source: keys/shiba/platform.x509.pem
│   │     sha256 (x509 fingerprint): 357d2283ba99c0dfcec36948c75e540da722369d68751c3aae27bd0868a8f9a3
│   │     • expires: Sep 26 18:42:44 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? releasekey.x509.pem
│   │     source: keys/shiba/releasekey.x509.pem
│   │     sha256 (x509 fingerprint): 9422fe8e6966afc77b650b65a6c46489eb736b306ff56152adffa71e02882a7d
│   │     • expires: Sep 26 18:42:45 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? sdk_sandbox.x509.pem
│   │     source: keys/shiba/sdk_sandbox.x509.pem
│   │     sha256 (x509 fingerprint): 0592e340cf37f3e0809e5eebfa20d97afb5ffafef1852f62a4e5374a9af0f7f8
│   │     • expires: Sep 26 18:42:46 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? shared.x509.pem
│   │     source: keys/shiba/shared.x509.pem
│   │     sha256 (x509 fingerprint): 90a05ba53eaab33c02b3763fe9f9441a1ef2c17ef591d38332fbcee98f56726f
│   │     • expires: Sep 26 18:42:47 2053 GMT
│   │     • subject: CN = GrapheneOS-Custom
│   ├── ? avb_pkmd.bin
│   │     source: keys/shiba/avb_pkmd.bin
│   │     sha256: 59e2c44d14fb3c871ea54330937e2ce70e59b7d32b0ff556ab64aee741080bbc
│   │     • size: 1,032 bytes
│   └── ? avb.pem
│         source: keys/shiba/avb.pem
│         sha256: efa854be5180581ecf1acca24981a809e35f84a98066545434203058057a9172
│         • size: 3,268 bytes
└── · Build artifacts (shiba)
      source: /home/guix/grapheneos/releases/
    └── · build 2026051201
          source: /home/guix/grapheneos/releases/2026051201/release-shiba-2026051201
        ├── ? shiba-factory-2026051201.zip
        │     source: releases/2026051201/release-shiba-2026051201/shiba-factory-2026051201.zip
        │     sha256: 9af848a68b8b2ccaf44ceb355116db68d322cc41ef8d6d10a56ca8c4c8159671
        │     • size: 1,693,979,392 bytes
        ├── ? shiba-img-2026051201.zip
        │     source: releases/2026051201/release-shiba-2026051201/shiba-img-2026051201.zip
        │     sha256: eb435f7f08ac4cffc02bf383439ef9d5420aff6c256a919042aed038ba3329e7
        │     • size: 1,640,575,906 bytes
        ├── ? shiba-install-2026051201.zip
        │     source: releases/2026051201/release-shiba-2026051201/shiba-install-2026051201.zip
        │     sha256: 2a46ed8d0c6cb4bc94e59a0a85c97d03cb24a4b3c2c160827f0d7cce22fea68b
        │     • size: 1,639,607,667 bytes
        └── ? shiba-ota_update-2026051201.zip
              source: releases/2026051201/release-shiba-2026051201/shiba-ota_update-2026051201.zip
              sha256: ebf728d2487725fecd5f4b085745d46aaebfb32bd2b550d33335f6770ea5d6a1
              • size: 1,266,711,619 bytes
```
