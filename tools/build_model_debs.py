#!/usr/bin/env python3
import os
import sys
import shutil
import tarfile
import subprocess

MODELS = [
    ("ru", "DictaKey Model: Russian", "vosk-model-small-ru-0.22", "model-ru",
     "Russian — offline speech recognition model for DictaKey (full vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-ru-small"),
        ("Conflicts", "com.noname122021.dictakey-model-ru-small"),
        ("Replaces", "com.noname122021.dictakey-model-ru-small"),
    ]),
    ("ru-small", "DictaKey Model: Russian (Small)", "vosk-model-small-ru-0.22-small", "model-ru",
     "Russian (Small) — lightweight offline speech recognition model for DictaKey (compact vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-ru"),
        ("Conflicts", "com.noname122021.dictakey-model-ru"),
        ("Replaces", "com.noname122021.dictakey-model-ru"),
    ]),
    ("en", "DictaKey Model: English", "vosk-model-small-en-us-0.15", "model-en",
     "English — offline speech recognition model for DictaKey (full vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-en-small"),
        ("Conflicts", "com.noname122021.dictakey-model-en-small"),
        ("Replaces", "com.noname122021.dictakey-model-en-small"),
    ]),
    ("en-small", "DictaKey Model: English (Small)", "vosk-model-small-en-us-0.15-small", "model-en",
     "English (Small) — lightweight offline speech recognition model for DictaKey (compact vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-en"),
        ("Conflicts", "com.noname122021.dictakey-model-en"),
        ("Replaces", "com.noname122021.dictakey-model-en"),
    ]),
    ("de", "DictaKey Model: German", "vosk-model-small-de-0.15", "model-de",
     "German — offline speech recognition model for DictaKey (full vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-de-small"),
        ("Conflicts", "com.noname122021.dictakey-model-de-small"),
        ("Replaces", "com.noname122021.dictakey-model-de-small"),
    ]),
    ("de-small", "DictaKey Model: German (Small)", "vosk-model-small-de-0.15-small", "model-de",
     "German (Small) — lightweight offline speech recognition model for DictaKey (compact vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-de"),
        ("Conflicts", "com.noname122021.dictakey-model-de"),
        ("Replaces", "com.noname122021.dictakey-model-de"),
    ]),
    ("fr", "DictaKey Model: French", "vosk-model-small-fr-0.22", "model-fr",
     "French — offline speech recognition model for DictaKey (full vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-fr-small"),
        ("Conflicts", "com.noname122021.dictakey-model-fr-small"),
        ("Replaces", "com.noname122021.dictakey-model-fr-small"),
    ]),
    ("fr-small", "DictaKey Model: French (Small)", "vosk-model-small-fr-0.22-small", "model-fr",
     "French (Small) — lightweight offline speech recognition model for DictaKey (compact vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-fr"),
        ("Conflicts", "com.noname122021.dictakey-model-fr"),
        ("Replaces", "com.noname122021.dictakey-model-fr"),
    ]),
    ("es", "DictaKey Model: Spanish", "vosk-model-small-es-0.42", "model-es",
     "Spanish — offline speech recognition model for DictaKey (full vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-es-small"),
        ("Conflicts", "com.noname122021.dictakey-model-es-small"),
        ("Replaces", "com.noname122021.dictakey-model-es-small"),
    ]),
    ("es-small", "DictaKey Model: Spanish (Small)", "vosk-model-small-es-0.42-small", "model-es",
     "Spanish (Small) — lightweight offline speech recognition model for DictaKey (compact vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-es"),
        ("Conflicts", "com.noname122021.dictakey-model-es"),
        ("Replaces", "com.noname122021.dictakey-model-es"),
    ]),
    ("it", "DictaKey Model: Italian", "vosk-model-small-it-0.22", "model-it",
     "Italian — offline speech recognition model for DictaKey (full vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-it-small"),
        ("Conflicts", "com.noname122021.dictakey-model-it-small"),
        ("Replaces", "com.noname122021.dictakey-model-it-small"),
    ]),
    ("it-small", "DictaKey Model: Italian (Small)", "vosk-model-small-it-0.22-small", "model-it",
     "Italian (Small) — lightweight offline speech recognition model for DictaKey (compact vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-it"),
        ("Conflicts", "com.noname122021.dictakey-model-it"),
        ("Replaces", "com.noname122021.dictakey-model-it"),
    ]),
    ("uk", "DictaKey Model: Ukrainian", "vosk-model-small-uk-v3-nano", "model-uk",
     "Ukrainian — offline speech recognition model for DictaKey (full vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-uk-small"),
        ("Conflicts", "com.noname122021.dictakey-model-uk-small"),
        ("Replaces", "com.noname122021.dictakey-model-uk-small"),
    ]),
    ("uk-small", "DictaKey Model: Ukrainian (Small)", "vosk-model-small-uk-v3-nano-small", "model-uk",
     "Ukrainian (Small) — lightweight offline speech recognition model for DictaKey (compact vocabulary).", [
        ("Provides", "com.noname122021.dictakey-model-uk"),
        ("Conflicts", "com.noname122021.dictakey-model-uk"),
        ("Replaces", "com.noname122021.dictakey-model-uk"),
    ]),
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

for lang, name, folder, symlink_name, desc, extra_fields in MODELS:
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
Name: {name}
Version: 1.0.0
Architecture: iphoneos-arm
Description: {desc}
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
