#!/usr/bin/env python3
import os
import sys
import shutil
import tarfile
import subprocess

MODELS = [
    ("ru", "Russian (Русский)", "vosk-model-small-ru-0.22", "model-ru", [
        ("Provides", "com.noname122021.dictakey-model-ru-small"),
        ("Conflicts", "com.noname122021.dictakey-model-ru-small"),
        ("Replaces", "com.noname122021.dictakey-model-ru-small"),
    ]),
    ("ru-small", "Russian Small (Русский Компактный)", "vosk-model-small-ru-0.22-small", "model-ru", [
        ("Provides", "com.noname122021.dictakey-model-ru"),
        ("Conflicts", "com.noname122021.dictakey-model-ru"),
        ("Replaces", "com.noname122021.dictakey-model-ru"),
    ]),
    ("en", "English (US)", "vosk-model-small-en-us-0.15", "model-en", []),
    ("uk", "Ukrainian (Українська)", "vosk-model-small-uk-v3-nano", "model-uk", []),
    ("de", "German (Deutsch)", "vosk-model-small-de-0.15", "model-de", []),
    ("fr", "French (Français)", "vosk-model-small-fr-0.22", "model-fr", []),
    ("es", "Spanish (Español)", "vosk-model-small-es-0.42", "model-es", []),
    ("it", "Italian (Italiano)", "vosk-model-small-it-0.22", "model-it", []),
]

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ASSETS_DIR = os.path.join(ROOT_DIR, "release-assets")
DEBS_DIR = os.path.join(ASSETS_DIR, "debs")
CYDIA_DEBS_DIR = os.path.join(ROOT_DIR, "cydia-repo", "debs")
WORK_DIR = "/tmp/dictakey-model-build"

os.makedirs(DEBS_DIR, exist_ok=True)
os.makedirs(CYDIA_DEBS_DIR, exist_ok=True)
if os.path.exists(WORK_DIR):
    shutil.rmtree(WORK_DIR)
os.makedirs(WORK_DIR, exist_ok=True)

for lang, name, folder, symlink_name, extra_fields in MODELS:
    tar_file = os.path.join(ASSETS_DIR, f"dictakey-model-{lang}.tar.gz")
    if not os.path.exists(tar_file):
        print(f"Skipping {lang}: {tar_file} not found")
        continue

    pkg_id = f"com.noname122021.dictakey-model-{lang}"
    stage = os.path.join(WORK_DIR, pkg_id)
    print(f"==> Packaging {name} ({lang})...")

    if os.path.exists(stage):
        shutil.rmtree(stage)

    debian_dir = os.path.join(stage, "DEBIAN")
    vosk_dir = os.path.join(stage, "var", "mobile", "Library", "vosk")
    os.makedirs(debian_dir, exist_ok=True)
    os.makedirs(vosk_dir, exist_ok=True)

    # Extract tar
    with tarfile.open(tar_file, "r:gz") as tar:
        tar.extractall(path=vosk_dir)

    # Create relative symlink: model-<lang> -> <folder>
    symlink_path = os.path.join(vosk_dir, symlink_name)
    if os.path.islink(symlink_path) or os.path.exists(symlink_path):
        os.remove(symlink_path)
    os.symlink(folder, symlink_path)

    # Control file
    extra_lines = "\n".join(f"{k}: {v}" for k, v in extra_fields)
    if extra_lines:
        extra_lines += "\n"
    control_content = f"""Package: {pkg_id}
Name: DictaKey Model ({name})
Version: 1.0.0
Architecture: iphoneos-arm
Description: Baked Vosk Kaldi speech recognition model on iOS 6. Requires DictaKey.
Maintainer: noname122021
Author: noname122021
Section: Addons (DictaKey)
Depends: com.noname122021.dictakey (>= 1.0.0)
{extra_lines}Tag: purpose::extension
"""
    with open(os.path.join(debian_dir, "control"), "w", encoding="utf-8") as f:
        f.write(control_content)

    # Post-install script
    postinst_path = os.path.join(debian_dir, "postinst")
    with open(postinst_path, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\nchmod -R 755 /var/mobile/Library/vosk\nchown -R mobile:mobile /var/mobile/Library/vosk\nexit 0\n")
    os.chmod(postinst_path, 0o755)

    # dpkg-deb with -Zgzip
    out_deb = os.path.join(DEBS_DIR, f"{pkg_id}_1.0.0_iphoneos-arm.deb")
    cmd = ["dpkg-deb", "-b", "-Zgzip", stage, out_deb]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Error packaging {pkg_id}: {res.stderr}")
        sys.exit(1)
    shutil.copy2(out_deb, CYDIA_DEBS_DIR)
    print(f"    Created: {out_deb} ({os.path.getsize(out_deb) // 1024 // 1024} MB)")

if os.path.exists(WORK_DIR):
    shutil.rmtree(WORK_DIR)
print(f"==> All model packages built successfully in {DEBS_DIR}")
