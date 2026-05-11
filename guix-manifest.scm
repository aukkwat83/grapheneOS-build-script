;; guix-manifest.scm — Guix package manifest สำหรับ build GrapheneOS
;; ใช้กับ: guix shell -m guix-manifest.scm --container --emulate-fhs --network ...
;;
;; ─── ที่มาของแต่ละ package (audit trail) ───────────────────────────────
;;
;; ทุกตัว = Guix official channel (gnu/packages/*.scm) — ตรวจสอบได้ด้วย:
;;   guix package -A "^<name>$"
;;
;; ─── ของที่ไม่อยู่ใน Guix (ต้อง install runtime) ───────────────────────
;;
;; 1) yarn — ไม่มีใน Guix official (มีแต่ r-yarn ของภาษา R ที่ไม่เกี่ยว)
;;    วิธีแก้: ใช้ `corepack enable yarn` (built-in มากับ Node ตั้งแต่ 16.10)
;;    หรือ `npm install -g yarn --prefix=$HOME/.local` (writable user prefix)
;;    audit: Node.js project's official supply chain (corepack signed by Node team)
;;
;; 2) repo (Google) — ไม่อยู่ใน Guix (Google upstream tool)
;;    ดาวน์โหลดจาก: https://storage.googleapis.com/git-repo-downloads/repo
;;    audit: Google official, signed by their CI; script ตรวจ checksum SHA256
;;
;; 3) AOSP prebuilts (clang, ckati, soong-go, mke2fs, etc.)
;;    มากับ source tree ของ GrapheneOS ใน prebuilts/ — verify ด้วย repo sync tag
;;    ใช้ผ่าน LD_LIBRARY_PATH=prebuilts/build-tools/linux-x86/lib64 (ไม่ต้อง patchelf)

(specifications->manifest
 '(;; ─── Toolchain หลัก (build native helpers + Soong bootstrap) ─────
   "gcc-toolchain@14"            ; ใช้ 14 (stable) — Guix master = 15.2.0 ก็ได้
   "make"
   "binutils"

   ;; ─── Java สำหรับ AOSP (signapk, dexlib, R8/proguard) ─────────────
   "openjdk@21:jdk"              ; AOSP main = 21 (lunch husky-cur-user ต้องใช้)

   ;; ─── Python (Soong + script ภายใน build) ─────────────────────────
   "python"                       ; default = 3.11
   "python-wrapper"               ; ทำ `python` → `python3`

   ;; ─── Build helpers ที่ AOSP/GrapheneOS ใช้ ───────────────────────
   "bc"          "bison"   "flex"   "gperf"
   "ccache"      "curl"    "rsync"  "git"     "git-lfs"
   "gnupg"       "imagemagick"     "libelf"
   "lz4"         "lzop"            "pngcrush"
   "openssl"                                  ; make_key + AVB signing
   "libxml2"     "libxslt"                    ; xsltproc, xmllint
   "squashfs-tools" "zip"  "unzip" "zlib"
   "util-linux"  "jq"

   ;; ─── Node.js (adevtool) ─────────────────────────────────────────
   ;; Guix มี node 22.14.0 — adevtool บอก engines: ">=18.0.0" ใช้ได้
   ;; yarn ใช้ผ่าน corepack (built-in กับ node 22)
   "node"

   ;; ─── Core POSIX tools (FHS container ไม่ provide เอง) ───────────
   "coreutils"   "findutils"  "grep"  "sed"  "gawk"  "which"
   "bash"        "tar"        "gzip"  "xz"

   ;; ─── CA certs + locales (HTTPS + UTF-8) ─────────────────────────
   "nss-certs"
   "glibc-locales"

   ;; ─── patchelf เผื่อ debug (ปกติไม่ใช้ — FHS container แก้ไปแล้ว) ─
   "patchelf"))
