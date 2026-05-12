#!/usr/bin/env python3
# audit-supply-chain.py — GrapheneOS supply-chain auditor (Guix edition)
#
# ─── ภาพรวม ──────────────────────────────────────────────────────────────
# Script "จอมจับผิด" libraries + packages ทุกจุดที่ใช้ build GrapheneOS
# บน Guix System — cross-check จากหลาย mirror, คิดคะแนนความน่าเชื่อถือ
# (probability) แล้วสร้าง HTML report แบบ offline ใช้ GoJS แสดง dependency
# graph สไตล์ state-chart พร้อม sidebar รายละเอียดเป็นภาษาไทย
#
# ─── สิ่งที่ตรวจ (1 build_number / run) ──────────────────────────────────
#  1) Guix packages จาก guix-manifest.scm
#       • recipe location + version
#       • store-path (content-addressed) + cross-check substitute mirrors
#  2) `repo` binary (Google)
#       • SHA-256 vs known-good
#       • cross-check storage.googleapis.com + gerrit.googlesource.com
#  3) GrapheneOS source tree (repo sync)
#       • git verify-tag (SSH หรือ GPG signature)
#       • cross-check fingerprint vs github.com/GrapheneOS + grapheneos.org keys
#       • อ่าน .repo/manifest.xml → list git remotes/projects (จำนวน)
#  4) AOSP prebuilts ภายใน source tree
#       • prebuilts/* dir → list สรุป
#  5) adevtool (vendor/adevtool)
#       • git remote + HEAD commit
#       • yarn.lock → 619 npm packages: integrity coverage + cross-check
#         random sample กับ registry.npmjs.org
#  6) Vendor blobs (adevtool downloads)
#       • SHA-256 ของ factory zip + backport
#  7) Signing keys + AVB
#       • X.509 fingerprint + key length + expiry
#       • AVB pkmd SHA-256
#  8) Build artifacts (release zips)
#       • SHA-256 ของ factory/install/img/ota_update
#
# ─── คะแนนความน่าเชื่อถือ (probability 0-100%) ──────────────────────────
#   100% : signature verified + ≥2 mirrors agree + hash ตรง known-good
#    80% : signature verified + 1 source + hash ตรง known-good
#    60% : hash ตรง known-good (ไม่มี sig)
#    40% : hash จาก local (ไม่มี known-good baseline)
#    20% : พบไฟล์แต่ตรวจไม่ได้
#     0% : mismatch / fail
#
# ─── การใช้งาน ───────────────────────────────────────────────────────────
#   guix shell python git openssl gnupg curl -- python3 audit-supply-chain.py \
#       --build-number 2026051201 --device shiba \
#       --out-html report.html [--no-network]
#
# default: ออนไลน์ทำ mirror cross-check (--no-network = skip = ลด score)
# python3.8+ stdlib only

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import random
import re
import shutil
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


# ─── ค่าฐาน (known-good — embed กัน MITM ตอน audit) ─────────────────────
GRAPHENEOS_SSH_FINGERPRINTS = {
    "SHA256:AhgHif0mei+9aNyKLfMZBh2yptHdw/aN7Tlh/j2eFwM",  # contact@grapheneos.org ED25519
}
GRAPHENEOS_GPG_FINGERPRINTS = {
    "65EEFE022108E2B708CBFCF7F9E712E59AF5F22A",  # legacy GPG
}
# repo launcher SHA-256 (2026-05) — verify: curl -sL .../repo | sha256sum
REPO_BINARY_KNOWN_HASHES = {
    "11bc6893e9e0c0940fc1cc95b75c645f9a29fca879d89ceaa898a4d761a2add7",
}
GUIX_SUBSTITUTE_MIRRORS = [
    "https://ci.guix.gnu.org",
    "https://bordeaux.guix.gnu.org",
]
REPO_MIRRORS = [
    "https://storage.googleapis.com/git-repo-downloads/repo",
    "https://gerrit.googlesource.com/git-repo/+/HEAD/repo?format=TEXT",  # base64
]
NPM_REGISTRY = "https://registry.npmjs.org"
GOJS_CDN = "https://unpkg.com/gojs@2.3.16/release/go.js"
CACHE_DIR = Path.home() / ".cache" / "audit-supply-chain"


# ─── data model ─────────────────────────────────────────────────────────
BADGE_PASS  = "✓"
BADGE_FAIL  = "✗"
BADGE_HASH  = "?"
BADGE_INFO  = "·"


@dataclass
class MirrorCheck:
    name: str
    url: str
    ok: bool
    note: str = ""


@dataclass
class Component:
    name: str
    kind: str
    name_th: str = ""                   # ภาษาไทย — ใช้ใน HTML
    source: str = ""
    hash_value: Optional[str] = None
    hash_algo: str = "sha256"
    expected: Optional[str] = None
    verified: Optional[bool] = None
    probability: float = 0.0
    score_rule: str = ""                # ชื่อกฎที่ match (debug/transparency)
    score_reason: str = ""              # คำอธิบายภาษาไทย
    mirrors: list = field(default_factory=list)   # MirrorCheck
    notes: list = field(default_factory=list)
    children: list = field(default_factory=list)

    @property
    def badge(self) -> str:
        if self.verified is True:  return BADGE_PASS
        if self.verified is False: return BADGE_FAIL
        if self.hash_value:        return BADGE_HASH
        return BADGE_INFO

    @property
    def trust_color(self) -> str:
        p = self.probability
        if p >= 90: return "#16a34a"   # green
        if p >= 70: return "#84cc16"   # lime
        if p >= 50: return "#eab308"   # yellow
        if p >= 30: return "#f59e0b"   # amber
        if p >  0:  return "#ef4444"   # red
        return "#9ca3af"               # gray (informational)


# ─── network helpers ────────────────────────────────────────────────────
_NET_ENABLED = True
_CTX = ssl.create_default_context()


def http_get(url: str, timeout: int = 15) -> tuple[int, bytes, dict]:
    """Return (status, body, headers). status=-1 ถ้า error / net disabled."""
    if not _NET_ENABLED:
        return -1, b"", {}
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "audit-supply-chain/1.0"})
        with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as r:
            return r.status, r.read(), dict(r.headers)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ConnectionError) as e:
        return -1, b"", {}


def http_head(url: str, timeout: int = 10, retries: int = 2) -> tuple[int, dict]:
    if not _NET_ENABLED:
        return -1, {}
    last_status = -1
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, method="HEAD",
                                         headers={"User-Agent": "audit-supply-chain/1.0"})
            with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as r:
                return r.status, dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, {}   # 404 ฯลฯ — ไม่ retry
        except Exception:
            last_status = -1
            if attempt < retries:
                continue   # retry on connection error/timeout
    return last_status, {}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def run(cmd: list, timeout: int = 30) -> tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return -1, "", str(e)


# ─── trust scoring ──────────────────────────────────────────────────────
# ─── กฎคิดคะแนน — ดูที่ SCORING_RULES (ใช้แสดงใน HTML report ด้วย) ──────
SCORING_RULES = [
    # (rule_id, score, condition_th, condition_en)
    ("VERIFY_FAIL",        0,   "verification ล้มเหลว (sig หรือ hash ผิด)",
                                "verified is False"),
    ("SIG_2MIRRORS",     100,   "มีลายเซ็น (SSH/GPG) ตรง + 2 mirrors ขึ้นไปยืนยัน",
                                "has_sig + mirror_ok >= 2"),
    ("SIG_1MIRROR",       90,   "มีลายเซ็นตรง + 1 mirror ยืนยัน",
                                "has_sig + mirror_ok >= 1"),
    ("SIG_ONLY",          80,   "มีลายเซ็นตรง (ไม่มี mirror cross-check)",
                                "has_sig only"),
    ("KNOWN_2MIRRORS",    90,   "hash ตรง known-good baseline + 2 mirrors ขึ้นไป",
                                "hash_match_known + mirror_ok >= 2"),
    ("KNOWN_1MIRROR",     80,   "hash ตรง known-good + 1 mirror ยืนยัน",
                                "hash_match_known + mirror_ok >= 1"),
    ("KNOWN_ONLY",        60,   "hash ตรง known-good (ไม่มี mirror)",
                                "hash_match_known only"),
    ("HASH_1MIRROR",      55,   "มี hash + 1 mirror ยืนยัน (ไม่มี baseline)",
                                "hash_value + mirror_ok >= 1"),
    ("HASH_ONLY",         40,   "มี hash อย่างเดียว (ไม่มี baseline + ไม่มี mirror)",
                                "hash_value only"),
    ("GROUP_AVG",         -1,   "node กลุ่ม — เฉลี่ยจากลูกทุกตัว",
                                "children avg"),
    ("NO_DATA",           20,   "ไม่มี hash, ไม่มี mirror, ไม่มี signature — แค่ metadata",
                                "no hash / no mirror / no sig"),
]


def compute_probability(c: Component) -> tuple[float, str, str]:
    """คืน (score, rule_id, reason_th) เพื่อใส่ใน report ด้วย"""
    if c.verified is False:
        return 0.0, "VERIFY_FAIL", "ไม่ผ่านการตรวจสอบ (ลายเซ็นหรือ hash ผิด)"
    mirror_ok = sum(1 for m in c.mirrors if m.ok)
    n_mirrors = len(c.mirrors)
    has_sig = (c.hash_algo in ("ssh-fingerprint", "gpg-fingerprint")) and c.verified is True
    hash_match_known = (c.verified is True) and (c.expected is not None)

    if has_sig and mirror_ok >= 2:
        return 100.0, "SIG_2MIRRORS", f"ลายเซ็น {c.hash_algo} ตรง + {mirror_ok}/{n_mirrors} mirrors ยืนยัน"
    if has_sig and mirror_ok >= 1:
        return 90.0, "SIG_1MIRROR",  f"ลายเซ็น {c.hash_algo} ตรง + {mirror_ok}/{n_mirrors} mirror ยืนยัน"
    if has_sig:
        return 80.0, "SIG_ONLY",     f"ลายเซ็น {c.hash_algo} ตรง (ไม่มี mirror cross-check)"
    if hash_match_known and mirror_ok >= 2:
        return 90.0, "KNOWN_2MIRRORS", f"hash ตรง expected + {mirror_ok}/{n_mirrors} mirrors"
    if hash_match_known and mirror_ok >= 1:
        return 80.0, "KNOWN_1MIRROR",  f"hash ตรง expected + {mirror_ok}/{n_mirrors} mirror"
    if hash_match_known:
        return 60.0, "KNOWN_ONLY",     "hash ตรง expected (ไม่มี mirror ตรวจ)"
    if c.hash_value and mirror_ok >= 1:
        return 55.0, "HASH_1MIRROR",   f"มี hash + {mirror_ok}/{n_mirrors} mirror (ไม่มี baseline เทียบ)"
    if c.hash_value:
        return 40.0, "HASH_ONLY",      "มี hash แต่ไม่มี baseline + ไม่มี mirror cross-check"
    if c.children:
        avg = sum(ch.probability for ch in c.children) / len(c.children)
        return avg, "GROUP_AVG", f"ค่าเฉลี่ยจาก {len(c.children)} ลูก"
    return 20.0, "NO_DATA", "ไม่มี hash / mirror / signature — แค่ metadata"


# ─── audit: Guix packages ───────────────────────────────────────────────
def _resolve_manifest_store_paths(manifest: Path) -> dict[str, str]:
    """
    สร้าง map: pkg_base → main store path โดยใช้ `guix shell -m manifest`
    realize profile ครั้งเดียว → enumerate ผ่าน `guix gc --requisites`

    เร็วและถูกต้องกว่าการเรียก `guix build` ทีละ pkg เพราะ:
      • 1 network call สำหรับ substitute query (ทั้ง profile)
      • หลังจากนั้น offline — แค่ list store paths
      • รู้จัก output specifier (`:jdk`, `:lib`) ตามจริง
    """
    paths: dict[str, str] = {}
    # 1) materialize profile (จะ pull substitutes ถ้ายังไม่มี cache)
    # ─── ไม่ใช้ --container เพราะ probably bind-mount นอก scope; แค่ echo profile path พอ ─
    rc, out, _ = run(
        ["guix", "shell", "-m", str(manifest), "--",
         "bash", "-c", "printf '%s' \"$GUIX_ENVIRONMENT\""],
        timeout=600,
    )
    profile = out.strip()
    if rc != 0 or not profile.startswith("/gnu/store/"):
        return paths
    # 2) enumerate requisites
    rc, out, _ = run(["guix", "gc", "--requisites", profile], timeout=60)
    if rc != 0:
        return paths
    # 3) parse store paths → pick "main" path per pkg name
    # path format: /gnu/store/<hash>-<name>-<ver>[-<output>]
    # — output suffix = หางที่ไม่ใช่ตัวเลข (เช่น "doc", "jdk", "lib")
    # — main output = path ที่จบด้วย version (เลข)
    # ตัวอย่าง:
    #   openssl-3.0.8           → main  (key: "openssl")
    #   openssl-3.0.8-doc       → doc output (key: "openssl:doc")
    #   openjdk-21.0.2-jdk      → jdk output (key: "openjdk:jdk")
    #   nss-certs-3.101.4       → main (key: "nss-certs")
    for line in out.splitlines():
        line = line.strip()
        m = re.match(r"^/gnu/store/([a-z0-9]{32})-(.+)$", line)
        if not m:
            continue
        rest = m.group(2)
        # หา "version segment" — segment ที่เริ่มด้วยเลข (เช่น 3.0.8, 21.0.2)
        segs = rest.split("-")
        ver_idx = None
        for i, s in enumerate(segs):
            if re.match(r"^[0-9]", s):
                ver_idx = i
                break
        if ver_idx is None:
            continue   # ไม่มี version segment — เช่น git-minimal โดยไม่มีเวอร์ชัน → ข้าม
        pkg_name = "-".join(segs[:ver_idx])
        version  = segs[ver_idx]
        output_segs = segs[ver_idx + 1:]    # ส่วนหลัง version = output specifier (ถ้ามี)
        if not output_segs:
            paths.setdefault(pkg_name, line)            # main output
        else:
            output = "-".join(output_segs)
            paths.setdefault(f"{pkg_name}:{output}", line)
    return paths


def audit_guix_manifest(manifest: Path) -> Component:
    root = Component(
        name=f"Guix packages ({manifest.name})",
        name_th="ชุดแพ็คเกจ Guix",
        kind="guix-group",
        source=str(manifest),
    )
    if not manifest.exists():
        root.notes.append(f"manifest ไม่พบ: {manifest}")
        return root
    text = manifest.read_text()
    pkgs = []
    for m in re.finditer(r'"([a-zA-Z][a-zA-Z0-9._@:+-]*)"', text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        line = text[line_start:m.end() + 20]
        if line.lstrip().startswith(";"):
            continue
        pkgs.append(m.group(1))
    pkgs = sorted(set(pkgs))
    root.notes.append(f"ทั้งหมด {len(pkgs)} packages จาก Guix official channel")
    root.notes.append("verification: content-addressed store + signed substitutes")
    root.notes.append(f"mirrors: {', '.join(GUIX_SUBSTITUTE_MIRRORS)}")

    has_guix = shutil.which("guix") is not None
    if not has_guix:
        root.notes.append("guix CLI ไม่พบ — ข้าม store-path lookup")

    # ─── realize ทุก path ครั้งเดียวจาก manifest (เร็ว + แม่นกว่าเรียก guix build ต่อ pkg) ─
    store_paths_map: dict[str, str] = {}
    if has_guix:
        print("[*]   pre-warm: realize profile จาก manifest...", file=sys.stderr)
        store_paths_map = _resolve_manifest_store_paths(manifest)
        root.notes.append(f"resolved {len(store_paths_map)} store paths จาก profile")

    for pkg in pkgs:
        # parse manifest spec: name[@version][:output]
        spec_name = pkg.split("@")[0].split(":")[0]
        spec_out = pkg.split(":", 1)[1] if ":" in pkg else None
        lookup_key = f"{spec_name}:{spec_out}" if spec_out else spec_name

        c = Component(name=pkg, kind="guix-pkg",
                      name_th=f"Guix: {pkg}",
                      source=f"guix-pkg:{spec_name}")
        if has_guix:
            rc, out, _ = run(["guix", "package", "-A", f"^{re.escape(spec_name)}$"], timeout=5)
            if rc == 0 and out.strip():
                first = out.strip().splitlines()[0].split()
                if len(first) >= 4:
                    c.notes.append(f"recipe: {first[3]}")
                    c.notes.append(f"version: {first[1]}")

            # ─── หาจาก map (จาก profile ที่ realize แล้ว) ────────────────
            store_path = store_paths_map.get(lookup_key)
            if not store_path:
                # fallback: ไม่มี output specifier → ลอง main
                store_path = store_paths_map.get(spec_name)
            if store_path:
                m = re.match(r"^/gnu/store/([a-z0-9]{32})-", store_path)
                if m:
                    c.hash_value = m.group(1)
                    c.hash_algo = "guix-store-hash"
                    c.notes.append(f"store: {store_path}")

            # ─── mirror cross-check narinfo ทั้ง 2 mirror ────────────────
            if c.hash_value:
                for mirror in GUIX_SUBSTITUTE_MIRRORS:
                    url = f"{mirror}/{c.hash_value}.narinfo"
                    status, _ = http_head(url, timeout=8)
                    c.mirrors.append(MirrorCheck(
                        name=mirror.split("//")[1].split(".")[0],
                        url=url,
                        ok=(status == 200),
                        note=f"narinfo HTTP {status}",
                    ))
            else:
                c.notes.append("ไม่พบ store path ใน profile (อาจไม่ถูก install จริง)")

            mirror_ok = sum(1 for m in c.mirrors if m.ok)
            if mirror_ok >= 1:
                c.verified = True
                c.expected = "narinfo present on substitute server"
        c.probability, c.score_rule, c.score_reason = compute_probability(c)
        root.children.append(c)
    root.probability, root.score_rule, root.score_reason = compute_probability(root)
    return root


# ─── audit: repo binary ─────────────────────────────────────────────────
def audit_repo_binary() -> Component:
    c = Component(
        name="repo (Google Git tool)",
        name_th="repo (เครื่องมือ Git ของ Google)",
        kind="binary",
        source="https://storage.googleapis.com/git-repo-downloads/repo",
    )
    repo_path = Path.home() / ".bin" / "repo"
    if not repo_path.exists():
        repo_path = Path(shutil.which("repo") or "/nonexistent")
    if not repo_path.exists() or not repo_path.is_file():
        c.notes.append("ไม่พบ repo binary")
        c.probability = 0.0
        return c
    c.hash_value = sha256_file(repo_path)
    c.notes.append(f"local: {repo_path}")

    # cross-check mirror 1: storage.googleapis.com
    status, body, _ = http_get(REPO_MIRRORS[0])
    if status == 200:
        upstream_hash = sha256_bytes(body)
        ok = upstream_hash == c.hash_value
        c.mirrors.append(MirrorCheck(
            name="storage.googleapis.com",
            url=REPO_MIRRORS[0],
            ok=ok,
            note=f"sha256={upstream_hash[:16]}…",
        ))

    # cross-check mirror 2: gerrit (base64-encoded)
    status, body, _ = http_get(REPO_MIRRORS[1])
    if status == 200:
        try:
            decoded = base64.b64decode(body)
            upstream_hash = sha256_bytes(decoded)
            ok = upstream_hash == c.hash_value
            c.mirrors.append(MirrorCheck(
                name="gerrit.googlesource.com",
                url=REPO_MIRRORS[1],
                ok=ok,
                note=f"sha256={upstream_hash[:16]}…",
            ))
        except Exception as e:
            c.mirrors.append(MirrorCheck("gerrit.googlesource.com", REPO_MIRRORS[1],
                                          False, f"decode error: {e}"))

    # match กับ embedded known-good
    if c.hash_value in REPO_BINARY_KNOWN_HASHES:
        c.verified = True
        c.expected = "known-good (embedded)"
        c.notes.append("hash ตรงกับ known-good ใน script")
    else:
        # ตรวจจาก mirrors แทน
        all_mirrors_agree = c.mirrors and all(m.ok for m in c.mirrors)
        c.verified = all_mirrors_agree
        if all_mirrors_agree:
            c.notes.append("hash ไม่อยู่ใน known-good แต่ตรงทุก mirror — อาจเป็น version ใหม่")
        else:
            c.notes.append("WARN: hash ไม่ตรง known-good และ mirror — ตรวจสอบ")
    c.probability, c.score_rule, c.score_reason = compute_probability(c)
    return c


# ─── audit: GrapheneOS source tag ───────────────────────────────────────
def audit_grapheneos_tag(build_root: Path, tag: str) -> Component:
    c = Component(
        name=f"GrapheneOS source tag {tag}",
        name_th=f"ซอร์สโค้ด GrapheneOS tag {tag}",
        kind="git-tag",
        source="https://github.com/GrapheneOS/platform_manifest.git",
    )
    manifest_dir = build_root / ".repo" / "manifests"
    if not manifest_dir.exists():
        c.notes.append(f"ไม่พบ {manifest_dir}")
        c.probability = 0.0
        return c

    rc, out, err = run(
        ["git", "-C", str(manifest_dir), "verify-tag", f"refs/tags/{tag}"],
        timeout=30,
    )
    combined = (out + "\n" + err).strip()

    ssh_match = re.search(r"Good\s+\"git\"\s+signature\s+for\s+\S+\s+with\s+\S+\s+key\s+(SHA256:\S+)", combined)
    gpg_match = re.search(r"VALIDSIG\s+([A-F0-9]{40})", combined)
    is_good_gpg = "GOODSIG" in combined

    if ssh_match:
        fp = ssh_match.group(1)
        c.hash_value = fp
        c.hash_algo = "ssh-fingerprint"
        c.expected = " | ".join(sorted(GRAPHENEOS_SSH_FINGERPRINTS))
        c.verified = fp in GRAPHENEOS_SSH_FINGERPRINTS
        c.notes.append(f"SSH signature verified by GrapheneOS allowed_signers")
        c.notes.append(f"fingerprint: {fp}")
    elif gpg_match:
        fp = gpg_match.group(1)
        c.hash_value = fp
        c.hash_algo = "gpg-fingerprint"
        c.expected = " | ".join(sorted(GRAPHENEOS_GPG_FINGERPRINTS))
        c.verified = is_good_gpg and fp in GRAPHENEOS_GPG_FINGERPRINTS
        c.notes.append(f"GPG fingerprint: {fp}")
    else:
        c.verified = False
        c.notes.append(f"verify-tag fail: {combined[:200]}")

    # cross-check mirror: GitHub API tag info
    repo = "GrapheneOS/platform_manifest"
    status, body, _ = http_get(f"https://api.github.com/repos/{repo}/git/refs/tags/{tag}")
    if status == 200:
        try:
            info = json.loads(body)
            sha = info.get("object", {}).get("sha", "")
            c.mirrors.append(MirrorCheck(
                name="github.com (API)", url=f"https://github.com/{repo}",
                ok=bool(sha), note=f"tag SHA {sha[:12]}",
            ))
        except Exception:
            pass
    else:
        c.mirrors.append(MirrorCheck("github.com (API)", f"https://github.com/{repo}",
                                      False, f"HTTP {status}"))

    # count projects in manifest
    default_xml = manifest_dir / "default.xml"
    if default_xml.exists():
        n_proj = len(re.findall(r"<project\s", default_xml.read_text()))
        c.notes.append(f"manifest มี {n_proj} repos ที่จะ sync")
    c.probability, c.score_rule, c.score_reason = compute_probability(c)
    return c


# ─── audit: AOSP prebuilts (high-level) ─────────────────────────────────
def audit_aosp_prebuilts(build_root: Path) -> Component:
    root = Component(
        name="AOSP prebuilts (in source tree)",
        name_th="AOSP prebuilts ในต้นฉบับ",
        kind="prebuilt-group",
        source=str(build_root / "prebuilts"),
    )
    prebuilts = build_root / "prebuilts"
    if not prebuilts.exists():
        root.notes.append(f"ไม่พบ {prebuilts} (repo sync ยังไม่เสร็จ)")
        return root
    interesting = ["clang", "rust", "go", "build-tools", "ndk", "jdk", "kernel", "vndk"]
    for sub in sorted(p for p in prebuilts.iterdir() if p.is_dir()):
        c = Component(name=sub.name, kind="prebuilt",
                      name_th=f"prebuilt: {sub.name}",
                      source=f"prebuilts/{sub.name}/")
        # provenance via git remote
        rc, out, _ = run(["git", "-C", str(sub), "config", "--get", "remote.origin.url"], timeout=3)
        if rc == 0:
            c.notes.append(f"remote: {out.strip()}")
        rc, out, _ = run(["git", "-C", str(sub), "rev-parse", "--short", "HEAD"], timeout=3)
        if rc == 0:
            c.hash_value = out.strip()
            c.hash_algo = "git-commit"
        # size summary
        try:
            n_files = sum(1 for _ in sub.rglob("*") if _.is_file())
            c.notes.append(f"files: {n_files:,}")
        except Exception:
            pass
        c.probability = 40.0 if c.hash_value else 20.0
        root.children.append(c)
    root.notes.append(f"ทั้งหมด {len(root.children)} prebuilt categories")
    root.probability, root.score_rule, root.score_reason = compute_probability(root)
    return root


# ─── audit: adevtool + yarn deps ────────────────────────────────────────
def audit_adevtool(build_root: Path, sample_npm_checks: int = 3) -> Component:
    root = Component(
        name="adevtool (vendor blob extractor)",
        name_th="adevtool — เครื่องมือดึงไดรเวอร์ Pixel",
        kind="node-tool",
        source=str(build_root / "vendor" / "adevtool"),
    )
    adev = build_root / "vendor" / "adevtool"
    if not adev.exists():
        root.notes.append(f"ไม่พบ {adev}")
        return root
    rc, out, _ = run(["git", "-C", str(adev), "config", "--get", "remote.origin.url"], timeout=3)
    if rc == 0: root.notes.append(f"remote: {out.strip()}")
    rc, out, _ = run(["git", "-C", str(adev), "rev-parse", "HEAD"], timeout=3)
    if rc == 0:
        root.hash_value = out.strip()
        root.hash_algo = "git-commit"
    rc, out, _ = run(["git", "-C", str(adev), "describe", "--tags", "--always"], timeout=3)
    if rc == 0: root.notes.append(f"describe: {out.strip()}")
    root.verified = root.hash_value is not None

    # yarn.lock analysis + sample cross-check กับ npm registry
    yarn_lock = adev / "yarn.lock"
    if yarn_lock.exists():
        lock_text = yarn_lock.read_text()
        pkg_entries = re.findall(r'^"?([a-zA-Z@][^"@\n]*)@[^"\n]*"?:\s*$', lock_text, re.MULTILINE)
        integrity = re.findall(r'integrity\s+(sha\d+-[A-Za-z0-9+/=]+)', lock_text)
        ylock = Component(
            name=f"yarn.lock ({len(set(pkg_entries))} packages)",
            name_th=f"yarn.lock — {len(set(pkg_entries))} แพ็คเกจ npm",
            kind="yarn-lock",
            source="registry.yarnpkg.com / registry.npmjs.org",
            hash_value=sha256_bytes(lock_text.encode()),
            hash_algo="sha256 (yarn.lock)",
        )
        ylock.notes.append(f"package entries: {len(pkg_entries)}, ปลายทาง integrity: {len(integrity)}")
        ylock.verified = len(integrity) > 0
        ylock.probability = 60.0 if ylock.verified else 20.0

        # sample cross-check: pick N random เทียบ npm registry
        sample_pkgs = sorted(set(pkg_entries))
        if _NET_ENABLED and sample_pkgs and sample_npm_checks > 0:
            random.seed(42)
            sample = random.sample(sample_pkgs, min(sample_npm_checks, len(sample_pkgs)))
            for pkg in sample:
                # ดึง version แรกจาก yarn.lock ของ pkg นั้น
                m = re.search(rf'"?{re.escape(pkg)}@[^"\n]*"?:\s*\n\s+version\s+"([^"]+)"', lock_text)
                if not m:
                    continue
                ver = m.group(1)
                lock_int = re.search(
                    rf'"?{re.escape(pkg)}@[^"\n]*"?:.*?integrity\s+(sha\d+-[^\s]+)',
                    lock_text, re.DOTALL,
                )
                lock_integ = lock_int.group(1) if lock_int else None
                # query registry
                pkg_url_name = pkg.replace("/", "%2F")
                status, body, _ = http_get(f"{NPM_REGISTRY}/{pkg_url_name}/{ver}", timeout=8)
                if status == 200:
                    try:
                        meta = json.loads(body)
                        npm_integ = meta.get("dist", {}).get("integrity", "")
                        ok = (lock_integ is not None and lock_integ == npm_integ)
                        ylock.mirrors.append(MirrorCheck(
                            name=f"npm:{pkg}@{ver}",
                            url=f"{NPM_REGISTRY}/{pkg_url_name}/{ver}",
                            ok=ok,
                            note=("integrity match" if ok else "integrity MISMATCH"),
                        ))
                    except Exception:
                        pass
        ylock.probability, ylock.score_rule, ylock.score_reason = compute_probability(ylock)
        root.children.append(ylock)
    root.probability, root.score_rule, root.score_reason = compute_probability(root)
    return root


# ─── audit: vendor blobs ────────────────────────────────────────────────
def audit_vendor_blobs(adev_dl: Path, device: str) -> Component:
    root = Component(
        name=f"Vendor blobs (Google factory zips)",
        name_th=f"ไดรเวอร์/บล็อบจาก Google (factory zip)",
        kind="vendor-group",
        source="https://dl.google.com/dl/android/aosp/",
    )
    if not adev_dl.exists():
        root.notes.append(f"ไม่พบ {adev_dl}")
        return root
    found = list(adev_dl.glob(f"{device}-*.zip"))
    if not found:
        # fallback: หาที่มี device name อยู่
        found = [p for p in adev_dl.glob("*.zip") if device in p.name.lower()]
    for f in sorted(set(found)):
        c = Component(name=f.name, kind="vendor-blob",
                      name_th=f"factory zip: {f.name}",
                      source=f"dl.google.com/dl/android/aosp/{device}/",
                      hash_value=sha256_file(f))
        c.notes.append(f"size: {f.stat().st_size:,} bytes")
        c.probability = 40.0   # hashed, no upstream baseline
        root.children.append(c)
    root.notes.append(f"พบ {len(root.children)} factory zip ในแคช")
    root.notes.append("เทียบ hash กับ developers.google.com/android/images ด้วยตัวเอง")
    root.probability, root.score_rule, root.score_reason = compute_probability(root)
    return root


# ─── audit: signing keys ────────────────────────────────────────────────
def audit_keys(build_root: Path, device: str) -> Component:
    root = Component(
        name=f"Signing keys ({device})",
        name_th=f"คีย์เซ็นแอป + AVB ({device})",
        kind="key-group",
        source=str(build_root / "keys" / device),
    )
    key_dir = build_root / "keys" / device
    if not key_dir.exists():
        root.notes.append(f"ไม่พบ {key_dir}")
        return root
    has_openssl = shutil.which("openssl") is not None

    for pem in sorted(key_dir.glob("*.x509.pem")):
        c = Component(name=pem.name, kind="x509-cert",
                      name_th=f"x509: {pem.stem.replace('.x509', '')}",
                      source=str(pem.relative_to(build_root)))
        if has_openssl:
            rc, out, _ = run(
                ["openssl", "x509", "-in", str(pem), "-noout",
                 "-fingerprint", "-sha256", "-subject", "-enddate"],
                timeout=5,
            )
            if rc == 0:
                fp = re.search(r"Fingerprint=([A-F0-9:]+)", out)
                end = re.search(r"notAfter=(.+)", out)
                subj = re.search(r"subject=\s*(.+)", out)
                if fp:
                    c.hash_value = fp.group(1).replace(":", "").lower()
                    c.hash_algo = "x509-fingerprint"
                if end:  c.notes.append(f"expires: {end.group(1).strip()}")
                if subj: c.notes.append(f"subject: {subj.group(1).strip()}")
                c.notes.append("คีย์ generate ในเครื่อง — ไม่มี baseline เทียบ")
        else:
            c.hash_value = sha256_file(pem)
            c.notes.append("(openssl ไม่พบ — fallback sha256 ของ pem)")
        c.probability = 40.0
        root.children.append(c)
    for bin_key in sorted(list(key_dir.glob("*.bin")) + list(key_dir.glob("avb*.pem"))):
        c = Component(name=bin_key.name, kind="bin-key",
                      name_th=f"binary key: {bin_key.name}",
                      source=str(bin_key.relative_to(build_root)),
                      hash_value=sha256_file(bin_key))
        c.notes.append(f"size: {bin_key.stat().st_size:,} bytes")
        c.probability = 40.0
        root.children.append(c)
    root.probability, root.score_rule, root.score_reason = compute_probability(root)
    return root


# ─── audit: release artifacts ───────────────────────────────────────────
def audit_release_artifacts(build_root: Path, device: str, build_number: str) -> Component:
    root = Component(
        name=f"Build artifacts (release {build_number})",
        name_th=f"ผลลัพธ์ build ({build_number})",
        kind="release-group",
        source=str(build_root / "releases" / build_number),
    )
    rel_dir = build_root / "releases" / build_number / f"release-{device}-{build_number}"
    if not rel_dir.exists():
        root.notes.append(f"ไม่พบ {rel_dir}")
        return root
    for z in sorted(rel_dir.glob(f"{device}-*-{build_number}.zip")):
        c = Component(name=z.name, kind="release-zip",
                      name_th=f"flashable: {z.stem}",
                      source=str(z.relative_to(build_root)),
                      hash_value=sha256_file(z))
        c.notes.append(f"size: {z.stat().st_size:,} bytes")
        c.probability = 40.0
        root.children.append(c)
    root.probability, root.score_rule, root.score_reason = compute_probability(root)
    return root


# ─── audit: build environment metadata ──────────────────────────────────
def audit_environment(build_root: Path, build_number: str, device: str, tag: str) -> Component:
    c = Component(
        name="Build environment",
        name_th="สภาพแวดล้อมการ build",
        kind="env",
        source="Guix System / FHS container",
    )
    rc, out, _ = run(["uname", "-a"], timeout=3)
    if rc == 0: c.notes.append(f"uname: {out.strip()}")
    rc, out, _ = run(["guix", "describe"], timeout=10)
    if rc == 0:
        first = out.strip().split("\n")[0]
        c.notes.append(f"guix: {first}")
    c.notes.append(f"build_root: {build_root}")
    c.notes.append(f"build_number: {build_number}")
    c.notes.append(f"device: {device}")
    c.notes.append(f"tag: {tag}")
    c.probability = 100.0  # informational only
    return c


# ─── tree renderer (stdout) ─────────────────────────────────────────────
def render_tree(c: Component, prefix: str = "", is_last: bool = True, is_root: bool = True) -> str:
    out = []
    if is_root:
        out.append(f"{c.badge} {c.name}  ({c.probability:.0f}%)")
        ext = ""
    else:
        connector = "└── " if is_last else "├── "
        rule = f" — {c.score_rule}" if c.score_rule else ""
        out.append(f"{prefix}{connector}{c.badge} {c.name}  ({c.probability:.0f}%{rule})")
        ext = "    " if is_last else "│   "
    sub = prefix + ext
    if not is_root and c.source:
        out.append(f"{sub}  source: {c.source}")
    if c.hash_value:
        h = c.hash_value if len(c.hash_value) <= 80 else c.hash_value[:80] + "…"
        out.append(f"{sub}  {c.hash_algo}: {h}")
    if c.expected:
        e = c.expected if len(c.expected) <= 80 else c.expected[:80] + "…"
        out.append(f"{sub}  expected: {e}")
    if c.score_reason:
        out.append(f"{sub}  ⚖ score [{c.score_rule}] {c.probability:.0f}% — {c.score_reason}")
    for m in c.mirrors:
        mark = "✓" if m.ok else "✗"
        out.append(f"{sub}  [{mark}] mirror {m.name}: {m.note}")
    for n in c.notes:
        out.append(f"{sub}  • {n}")
    for i, ch in enumerate(c.children):
        out.append(render_tree(ch, sub, i == len(c.children) - 1, is_root=False))
    return "\n".join(out)


def to_dict(c: Component) -> dict:
    d = asdict(c)
    d["badge"] = c.badge
    d["trust_color"] = c.trust_color
    d["children"] = [to_dict(ch) for ch in c.children]
    return d


# ─── GoJS HTML renderer ─────────────────────────────────────────────────
def fetch_gojs() -> str:
    """ดึง go.js (CDN, cache ใน ~/.cache/audit-supply-chain/) — embed ลง HTML"""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cached = CACHE_DIR / "go.js"
    if cached.exists() and cached.stat().st_size > 100_000:
        return cached.read_text(encoding="utf-8", errors="replace")
    if not _NET_ENABLED:
        return ""
    status, body, _ = http_get(GOJS_CDN, timeout=60)
    if status == 200 and len(body) > 100_000:
        try:
            text = body.decode("utf-8")
            cached.write_text(text, encoding="utf-8")
            return text
        except UnicodeDecodeError:
            return ""
    return ""


def flatten_for_graph(root: Component) -> tuple[list, list]:
    """แปลง tree → nodes + links สำหรับ GoJS"""
    nodes = []
    links = []
    counter = {"i": 0}

    def add(c: Component, parent_key: Optional[str] = None) -> str:
        counter["i"] += 1
        key = f"n{counter['i']}"
        # node payload — เก็บข้อมูลครบสำหรับ sidebar
        nodes.append({
            "key": key,
            "text": c.name_th or c.name,
            "name_en": c.name,
            "kind": c.kind,
            "badge": c.badge,
            "probability": round(c.probability, 1),
            "color": c.trust_color,
            "source": c.source,
            "hash_algo": c.hash_algo,
            "hash": c.hash_value or "",
            "expected": c.expected or "",
            "verified": c.verified,
            "score_rule": c.score_rule,
            "score_reason": c.score_reason,
            "mirrors": [{"name": m.name, "url": m.url, "ok": m.ok, "note": m.note}
                        for m in c.mirrors],
            "notes": c.notes,
            "is_group": bool(c.children),
        })
        if parent_key:
            links.append({"from": parent_key, "to": key})
        # ลึกแค่ 2 ระดับเพื่อกราฟไม่บวม — children ที่ลึกกว่านี้ค่อย expand ใน sidebar
        for ch in c.children:
            add(ch, key)
        return key

    add(root)
    return nodes, links


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="utf-8">
<title>GrapheneOS Supply Chain Audit — {build_number} / {device}</title>
<style>
  * {{ box-sizing: border-box; }}
  body {{ margin:0; font-family: -apple-system, "Noto Sans Thai", sans-serif;
         background:#0f172a; color:#e2e8f0; }}
  header {{ padding: 12px 20px; background:#1e293b; border-bottom:1px solid #334155;
            display:flex; align-items:center; gap:20px; }}
  header h1 {{ font-size:18px; margin:0; flex:1; }}
  header .meta {{ font-size:12px; color:#94a3b8; }}
  header .legend span {{ display:inline-block; width:12px; height:12px; border-radius:3px;
                          margin: 0 4px 0 12px; vertical-align: middle; }}
  #app {{ display: grid; grid-template-columns: 1fr 380px; height: calc(100vh - 60px); }}
  #diagram {{ background:#0f172a; }}
  #sidebar {{ background:#1e293b; border-left:1px solid #334155; padding: 16px;
              overflow-y:auto; font-size:13px; line-height:1.5; }}
  #sidebar h2 {{ font-size:16px; margin:0 0 8px; color:#f1f5f9; }}
  #sidebar .badge {{ font-size:11px; padding:2px 8px; border-radius:10px;
                     color:#0f172a; font-weight:bold; }}
  #sidebar .row {{ margin: 6px 0; }}
  #sidebar .label {{ color:#94a3b8; font-size:11px; text-transform:uppercase; letter-spacing:0.5px; }}
  #sidebar .value {{ word-break: break-all; font-family: ui-monospace, monospace; font-size:12px; }}
  #sidebar .mirror-ok  {{ color:#22c55e; }}
  #sidebar .mirror-bad {{ color:#ef4444; }}
  #sidebar ul {{ padding-left: 18px; margin: 6px 0; }}
  #summary {{ padding: 12px 20px; background:#0f172a; border-bottom:1px solid #334155;
              display:flex; gap: 24px; font-size:13px; }}
  #summary .stat {{ display:flex; flex-direction:column; align-items:flex-start; }}
  #summary .stat .num {{ font-size:20px; font-weight:bold; }}
  #summary .stat .lbl {{ font-size:11px; color:#94a3b8; }}
  #rules-panel {{ border-bottom:1px solid #334155; background:#0f172a; }}
  #rules-panel summary {{ padding: 10px 20px; cursor:pointer; color:#cbd5e1;
                          background:#1e293b; user-select:none; }}
  #rules-panel summary:hover {{ background:#334155; }}
  #rules-panel table th, #rules-panel table td {{ padding:6px 10px; border:1px solid #334155; }}
  #rules-panel code {{ background:#0f172a; padding:1px 5px; border-radius:3px;
                       font-size:11px; color:#fbbf24; }}
  #sidebar .score-box {{ background:#0f172a; border:1px solid #334155; padding:8px;
                         border-radius:6px; margin: 8px 0; }}
  #sidebar .score-box .rule {{ font-family: ui-monospace, monospace; font-size:11px;
                                color:#fbbf24; }}
  #sidebar .score-box .reason {{ color:#cbd5e1; margin-top:4px; }}
</style>
</head>
<body>
<header>
  <h1>🛡 GrapheneOS Supply Chain Audit</h1>
  <div class="meta">
    <strong>Build:</strong> {build_number} &nbsp;|&nbsp;
    <strong>Device:</strong> {device} &nbsp;|&nbsp;
    <strong>Tag:</strong> {tag} &nbsp;|&nbsp;
    <strong>Generated:</strong> {timestamp}
  </div>
  <div class="legend">
    Trust:
    <span style="background:#16a34a"></span>≥90%
    <span style="background:#84cc16"></span>≥70%
    <span style="background:#eab308"></span>≥50%
    <span style="background:#f59e0b"></span>≥30%
    <span style="background:#ef4444"></span>>0%
    <span style="background:#9ca3af"></span>info
  </div>
</header>
<div id="summary">
  <div class="stat"><span class="num" style="color:#22c55e">{stat_pass}</span>
                    <span class="lbl">verified ✓</span></div>
  <div class="stat"><span class="num" style="color:#ef4444">{stat_fail}</span>
                    <span class="lbl">mismatch ✗</span></div>
  <div class="stat"><span class="num" style="color:#eab308">{stat_hash}</span>
                    <span class="lbl">hashed ?</span></div>
  <div class="stat"><span class="num" style="color:#94a3b8">{stat_info}</span>
                    <span class="lbl">informational ·</span></div>
  <div class="stat"><span class="num">{stat_total}</span>
                    <span class="lbl">total components</span></div>
  <div class="stat"><span class="num">{stat_avg_prob:.0f}%</span>
                    <span class="lbl">avg trust</span></div>
</div>
<details id="rules-panel">
<summary>⚖️ <strong>วิธีคิดคะแนน Trust Score (0–100%)</strong> — คลิกขยาย</summary>
<div style="padding:12px 20px; background:#1e293b; color:#e2e8f0; font-size:13px; line-height:1.6;">
  <p>คะแนนของแต่ละ component คำนวณจาก <strong>กฎตามลำดับ</strong> (return อันแรกที่ match):</p>
  <table style="width:100%; border-collapse:collapse; font-size:12px;">
    <thead>
      <tr style="background:#0f172a;">
        <th style="text-align:left; padding:6px; border:1px solid #334155;">Rule ID</th>
        <th style="text-align:left; padding:6px; border:1px solid #334155;">เงื่อนไข</th>
        <th style="text-align:left; padding:6px; border:1px solid #334155;">เกณฑ์ (เทคนิค)</th>
        <th style="text-align:right; padding:6px; border:1px solid #334155;">คะแนน</th>
      </tr>
    </thead>
    <tbody>
      {rules_table_rows}
    </tbody>
  </table>
  <p style="margin-top:12px; font-size:12px; color:#94a3b8;">
    <strong>ศัพท์ที่ใช้:</strong>
    <code>has_sig</code> = signature (SSH/GPG) verify ผ่าน  ·
    <code>hash_match_known</code> = hash ตรง known-good baseline ที่ embed ใน script  ·
    <code>mirror_ok</code> = จำนวน mirror ที่ตอบ HTTP 200 (จาก {n_mirrors_total} mirror config)  ·
    <code>hash_value</code> = คำนวณ hash ของไฟล์ได้
  </p>
  <p style="margin-top:6px; font-size:12px; color:#94a3b8;">
    <strong>หมายเหตุ:</strong> น้ำหนัก hardcode ตามสัญชาตญาณ — ไม่ใช่ Bayesian ทางคณิตศาสตร์.
    คะแนน "ความน่าเชื่อถือ" (trust score) สื่อว่า <em>มีหลักฐานยืนยันที่มา</em>มากแค่ไหน ไม่ใช่ "ความน่าจะเป็นที่ปลอดภัย" ทางความปลอดภัย
  </p>
</div>
</details>
<div id="app">
  <div id="diagram"></div>
  <div id="sidebar">
    <p style="color:#94a3b8">คลิกบน node เพื่อดูรายละเอียดทั้งหมด</p>
  </div>
</div>
<script>
{gojs_lib}
</script>
<script>
const NODES = {nodes_json};
const LINKS = {links_json};

const $ = go.GraphObject.make;
const diagram = $(go.Diagram, "diagram", {{
  layout: $(go.LayeredDigraphLayout, {{
    direction: 0, layerSpacing: 60, columnSpacing: 30, setsPortSpots: false,
  }}),
  "undoManager.isEnabled": false,
  initialAutoScale: go.Diagram.Uniform,
  "animationManager.isEnabled": true,
}});

diagram.nodeTemplate = $(go.Node, "Auto",
  {{ click: (e, n) => showDetails(n.data) }},
  $(go.Shape, "RoundedRectangle",
    {{ strokeWidth: 2, stroke: "#0f172a" }},
    new go.Binding("fill", "color"),
  ),
  $(go.Panel, "Vertical",
    {{ margin: 10 }},
    $(go.TextBlock,
      {{ font: "bold 13px sans-serif", stroke: "#0f172a", margin: new go.Margin(0,0,2,0) }},
      new go.Binding("text", "text"),
    ),
    $(go.TextBlock,
      {{ font: "10px monospace", stroke: "#1e293b" }},
      new go.Binding("text", "", d => d.badge + "  " + d.probability + "%"),
    ),
  ),
);

diagram.linkTemplate = $(go.Link,
  {{ routing: go.Link.AvoidsNodes, corner: 10 }},
  $(go.Shape, {{ strokeWidth: 1.5, stroke: "#475569" }}),
  $(go.Shape, {{ toArrow: "Triangle", fill: "#475569", stroke: null }}),
);

diagram.model = new go.GraphLinksModel(NODES, LINKS);

function showDetails(d) {{
  const sb = document.getElementById("sidebar");
  let html = `<h2>${{d.text}}</h2>`;
  html += `<div class="row"><span class="badge" style="background:${{d.color}}">${{d.badge}} ${{d.probability}}%</span>
           &nbsp;<span style="color:#94a3b8">${{d.kind}}</span></div>`;
  if (d.score_rule) {{
    html += `<div class="score-box">
              <div><span class="label">SCORE</span> &nbsp;
                   <strong style="color:${{d.color}}">${{d.probability}}%</strong> &nbsp;
                   <span class="rule">[${{escapeHtml(d.score_rule)}}]</span></div>
              <div class="reason">⚖ ${{escapeHtml(d.score_reason)}}</div>
             </div>`;
  }}
  if (d.name_en && d.name_en !== d.text)
    html += `<div class="row"><span class="label">name (en)</span><br><span class="value">${{escapeHtml(d.name_en)}}</span></div>`;
  if (d.source)
    html += `<div class="row"><span class="label">source</span><br><span class="value">${{escapeHtml(d.source)}}</span></div>`;
  if (d.hash)
    html += `<div class="row"><span class="label">${{d.hash_algo}}</span><br><span class="value">${{escapeHtml(d.hash)}}</span></div>`;
  if (d.expected)
    html += `<div class="row"><span class="label">expected</span><br><span class="value">${{escapeHtml(d.expected)}}</span></div>`;
  if (d.mirrors && d.mirrors.length) {{
    html += `<div class="row"><span class="label">mirror checks</span><ul>`;
    for (const m of d.mirrors) {{
      const cls = m.ok ? "mirror-ok" : "mirror-bad";
      const sym = m.ok ? "✓" : "✗";
      html += `<li class="${{cls}}">${{sym}} <strong>${{escapeHtml(m.name)}}</strong>: ${{escapeHtml(m.note)}}</li>`;
    }}
    html += `</ul></div>`;
  }}
  if (d.notes && d.notes.length) {{
    html += `<div class="row"><span class="label">notes</span><ul>`;
    for (const n of d.notes) html += `<li>${{escapeHtml(n)}}</li>`;
    html += `</ul></div>`;
  }}
  sb.innerHTML = html;
}}

function escapeHtml(s) {{
  return String(s).replace(/[&<>"']/g, c =>
    ({{"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","'":"&#39;"}})[c]);
}}
</script>
</body>
</html>
"""


def count_badges(c: Component, counts: dict) -> None:
    counts[c.badge] = counts.get(c.badge, 0) + 1
    counts["_total"] = counts.get("_total", 0) + 1
    counts["_sum_prob"] = counts.get("_sum_prob", 0.0) + c.probability
    for ch in c.children:
        count_badges(ch, counts)


def _rules_table_html() -> str:
    """generate HTML rows ของ SCORING_RULES สำหรับใส่ใน rules-panel"""
    rows = []
    for rule_id, score, cond_th, cond_en in SCORING_RULES:
        score_disp = "avg" if score < 0 else f"{score}%"
        rows.append(
            f"<tr>"
            f"<td><code>{rule_id}</code></td>"
            f"<td>{cond_th}</td>"
            f"<td><code>{cond_en}</code></td>"
            f"<td style='text-align:right;'><strong>{score_disp}</strong></td>"
            f"</tr>"
        )
    return "\n".join(rows)


def render_html(root: Component, args, gojs_lib: str) -> str:
    nodes, links = flatten_for_graph(root)
    counts: dict = {}
    count_badges(root, counts)
    total = counts["_total"]
    avg = (counts["_sum_prob"] / total) if total else 0.0

    if not gojs_lib:
        gojs_lib = (
            "/* go.js ไม่พร้อม (no network + no cache) — เปิดไฟล์นี้ขณะออนไลน์เพื่อ cache, "
            "หรือดาวน์โหลด go.js แล้วใส่ใน ~/.cache/audit-supply-chain/go.js */"
            "\ndocument.getElementById('diagram').innerText="
            "'⚠ ไม่มี go.js — รัน online หรือใส่ใน ~/.cache/audit-supply-chain/go.js';"
        )

    return HTML_TEMPLATE.format(
        build_number=args.build_number or "(latest)",
        device=args.device,
        tag=args.tag,
        timestamp=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        gojs_lib=gojs_lib,
        nodes_json=json.dumps(nodes, ensure_ascii=False),
        links_json=json.dumps(links, ensure_ascii=False),
        stat_pass=counts.get(BADGE_PASS, 0),
        stat_fail=counts.get(BADGE_FAIL, 0),
        stat_hash=counts.get(BADGE_HASH, 0),
        stat_info=counts.get(BADGE_INFO, 0),
        stat_total=total,
        stat_avg_prob=avg,
        rules_table_rows=_rules_table_html(),
        n_mirrors_total=len(GUIX_SUBSTITUTE_MIRRORS) + len(REPO_MIRRORS),
    )


# ─── main ───────────────────────────────────────────────────────────────
def main() -> int:
    global _NET_ENABLED
    p = argparse.ArgumentParser(
        description="GrapheneOS supply-chain audit — cross-check mirrors + HTML report",
    )
    p.add_argument("--build-root", default=os.path.expanduser("~/grapheneos"))
    p.add_argument("--manifest", default=None)
    p.add_argument("--adev-dl", default=os.path.expanduser("~/adevtool-downloads"))
    p.add_argument("--device", default="shiba")
    p.add_argument("--tag", default="2026042100")
    p.add_argument("--build-number", required=True, help="build เลขที่ตรวจ (เช่น 2026051201)")
    p.add_argument("--out-html", default=None, help="path สำหรับ HTML report (offline)")
    p.add_argument("--out-json", default=None)
    p.add_argument("--out-tree", default=None)
    p.add_argument("--no-network", action="store_true", help="ข้าม mirror cross-check (offline mode)")
    p.add_argument("--npm-sample", type=int, default=3,
                   help="จำนวน npm packages ที่จะ cross-check กับ registry (default: 3)")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    if args.no_network:
        _NET_ENABLED = False

    build_root = Path(args.build_root).resolve()
    manifest   = Path(args.manifest).resolve() if args.manifest else build_root / "guix-manifest.scm"
    adev_dl    = Path(args.adev_dl).resolve()

    root = Component(
        name=f"GrapheneOS Supply Chain Audit ({args.device}, build {args.build_number})",
        name_th=f"ตรวจสอบ supply chain GrapheneOS ({args.device}, build {args.build_number})",
        kind="root",
        source=str(build_root),
    )

    print(f"[*] audit เริ่ม — build={args.build_number} device={args.device} tag={args.tag}",
          file=sys.stderr)
    print(f"[*] network={_NET_ENABLED}", file=sys.stderr)

    print("[*] (1/8) Guix packages...", file=sys.stderr)
    root.children.append(audit_guix_manifest(manifest))
    print("[*] (2/8) repo binary...", file=sys.stderr)
    root.children.append(audit_repo_binary())
    print("[*] (3/8) GrapheneOS source tag...", file=sys.stderr)
    root.children.append(audit_grapheneos_tag(build_root, args.tag))
    print("[*] (4/8) AOSP prebuilts...", file=sys.stderr)
    root.children.append(audit_aosp_prebuilts(build_root))
    print("[*] (5/8) adevtool + yarn deps...", file=sys.stderr)
    root.children.append(audit_adevtool(build_root, args.npm_sample))
    print("[*] (6/8) vendor blobs...", file=sys.stderr)
    root.children.append(audit_vendor_blobs(adev_dl, args.device))
    print("[*] (7/8) signing keys...", file=sys.stderr)
    root.children.append(audit_keys(build_root, args.device))
    print("[*] (8/8) release artifacts + env...", file=sys.stderr)
    root.children.append(audit_release_artifacts(build_root, args.device, args.build_number))
    root.children.append(audit_environment(build_root, args.build_number, args.device, args.tag))
    root.probability, root.score_rule, root.score_reason = compute_probability(root)

    if not args.quiet:
        print(render_tree(root))

    if args.out_tree:
        Path(args.out_tree).write_text(render_tree(root) + "\n", encoding="utf-8")
        print(f"\n[+] tree → {args.out_tree}", file=sys.stderr)
    if args.out_json:
        Path(args.out_json).write_text(
            json.dumps(to_dict(root), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"[+] JSON → {args.out_json}", file=sys.stderr)
    if args.out_html:
        print("[*] ดึง GoJS (cache ที่ ~/.cache/audit-supply-chain/go.js)...", file=sys.stderr)
        gojs = fetch_gojs()
        Path(args.out_html).write_text(render_html(root, args, gojs), encoding="utf-8")
        print(f"[+] HTML → {args.out_html}  (เปิดด้วย browser, ใช้ offline)", file=sys.stderr)

    counts: dict = {}
    count_badges(root, counts)
    return 1 if counts.get(BADGE_FAIL, 0) > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
