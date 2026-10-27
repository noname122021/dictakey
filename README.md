# DictaKey

<p align="center">
  <img src="assets/icon.png" width="96" height="96" alt="DictaKey Icon" style="border-radius: 20px;"><br>
  <b>Offline Multilingual Voice Dictation for iOS 6</b><br>
  <i>Powered by Vosk Kaldi, OpenFST ConstFst, and Skeuomorphic UIKit Design.</i>
</p>

<p align="center">
  <a href="https://noname122021.github.io/cydia-repo/#dictakey"><img src="https://img.shields.io/badge/Cydia%20Repo-Open%20Repository-orange.svg?style=for-the-badge" alt="Cydia Repo"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-6.0%20--%206.1.6-blue.svg" alt="iOS 6.0 - 6.1.6">
  <img src="https://img.shields.io/badge/arch-ARMv7%20(32--bit)-success.svg" alt="ARMv7 32-bit">
  <img src="https://img.shields.io/badge/license-MIT%20%2F%20Apache%202.0-lightgrey.svg" alt="License">
</p>

<p align="center">
  <a href="README.md"><b>English</b></a> • <a href="README.ru.md"><b>Русский</b></a>
</p>

> ### 📦 **[Open DictaKey in Cydia Repository (GitHub Pages)](https://noname122021.github.io/cydia-repo/#dictakey)**
> - **One-Tap Cydia Install:** [Add Source to Cydia (`cydia://`)](cydia://url/https://cydia.saurik.com/api/share#?source=https://noname122021.github.io/cydia-repo/)
> - **Cydia APT URL:** `https://noname122021.github.io/cydia-repo/`

---

## Showcase

| Keyboard Integration (Notes.app) | Settings & Language Management |
|:---:|:---:|
| <img src="assets/keyboard.png" width="460" alt="DictaKey Keyboard"> | <img src="assets/settings.png" width="460" alt="DictaKey Preferences"> |

---

## Overview

**DictaKey** brings modern, completely offline, on-device voice dictation to legacy iOS 6 devices (Apple A4/A5/A6, 32-bit ARMv7). It integrates a skeuomorphic microphone dictation key into the native iOS keyboard, streams audio via a low-latency ring buffer directly to a Kaldi neural acoustic model, and types recognized words into any text field in real time.

DictaKey requires **no internet connection**, **no external servers**, and **no Siri services**. All speech recognition runs entirely on the device processor.

---

## Key Features

- **Native Skeuomorphic Dictation Key**
  - Custom `DKButtonView` drawn using CoreGraphics with authentic iOS 6 etched shadows, specular gradients, and micro-embossed bevels.
  - Real-time RMS audio visualizer waveform rendered inside the microphone glyph while recording.
  - Seamlessly injected into `UIKeyboardImpl` alongside standard keyboard controls on both iPad and iPhone layouts.

- **Fast Integer VAD (Voice Activity Detection)**
  - Pure integer energy gate ($\sum |s_i|$ over 20ms frames) running in under 1 µs per frame on Cortex-A8/A9.
  - 300ms pre-speech buffer preserves initial soft consonants; 400ms hangover prevents word clipping.
  - Drops silent pauses immediately, cutting acoustic model CPU load by up to 40% and eliminating decoding backlog.

- **Zero-Overhead Typing & Instant Start**
  - Opening the keyboard consumes **0% CPU and 0 MB RAM** — model loading only triggers when the microphone key is tapped.
  - Key turns active red immediately (`SetState(1)`) and buffers audio into a lock-free ring buffer instantly.
  - Recognizer reuse via `vosk_recognizer_reset`: subsequent recognition runs yield the first recognized word in **~0.5 seconds even on single-core iPhone 4**!

- **Context-Aware Keyboard Hiding**
  - Automatically hides dictation key on URL input bars (`UIKeyboardTypeURL`), number pads, and phone dials to preserve layout integrity.

- **Spoken Punctuation Engine**
  - Spoken punctuation for 7 languages:
    - **Russian (RU):** `запятая` $\to$ `,`, `двоеточие` $\to$ `:`, `тире` $\to$ ` —`, `дефис` $\to$ `-`.
    - **English (EN):** `comma` $\to$ `,`, `period` $\to$ `.`, `colon` $\to$ `:`, `dash` $\to$ ` —`, `hyphen` $\to$ `-`, `exclamation` $\to$ `!`, `question` $\to$ `?`.
    - **Ukrainian (UK):** `кома` $\to$ `,`, `двокрапка` $\to$ `:`, `тире` $\to$ ` —`, `дефіс` $\to$ `-`.
    - **German (DE), French (FR), Spanish (ES), Italian (IT):** Full native punctuation word mappings.
  - Automatic space trimming (`DeleteBack(1)`) so punctuation attaches cleanly to the preceding word without leading spaces.

- **Dynamic Cydia / APT Model Distribution & Pre-Baked Caches**
  - Base tweak package is ultra-lightweight (**4.2 MB**).
  - Heavy Kaldi recognition models are distributed as modular Cydia `.deb` packages (14 packages across 7 languages, offering both Regular and Small variants).
  - All 14 models come pre-baked with kernel mmap-aligned `HCLr.fst` graphs and pre-computed acoustic/i-vector covariance caches (`final.mdl.cache`, `final.ie.cache`), cutting cold model initialization time in half.
  - PreferenceLoader settings panel dynamically scans `/var/mobile/Library/vosk/` for installed models. Only installed languages appear as toggle switches, resolved automatically to localized names via `[NSLocale currentLocale]`.

---

## Installation via Cydia

1. Open **Cydia** on your jailbroken iOS 6 device.
2. Go to **Manage** $\to$ **Sources** $\to$ **Edit** $\to$ **Add**.
3. Enter the repository URL:
   ```
   https://noname122021.github.io/cydia-repo/
   ```
   *(Or open that URL in Safari on your device and tap **Add to Cydia**)*.
4. Search for and install **DictaKey** (under **Sections** $\to$ **Tweaks**).
5. Install your language models (under **Sections** $\to$ **Addons (DictaKey)**):
   - **Regular models** (`DictaKey Model: <Language>`): full vocabulary for dual-core devices (iPad 2/3/4/mini, iPhone 4S/5).
   - **Small models** (`DictaKey Model: <Language> (Small)`): lightweight 15k vocabulary optimized for single-core devices (iPhone 4, iPod touch 4).

---

## Supported Devices

- **iPhone 4** (Apple A4 single-core 800 MHz, iOS 6.1.3)
- **iPad mini 1st gen** (Apple A5 dual-core 1.0 GHz, iOS 6.1.2 / 6.1.3)
- **iPad 2 / iPad 3 / iPad 4** (iOS 6.0 – 6.1.3)
- **iPhone 4S / iPhone 5** (iOS 6.0 – 6.1.4)
- **iPod touch 4th / 5th gen** (iOS 6.0 – 6.1.6)

---

## Technical Architecture

```
[ Microphone Audio ] 
        │ 16kHz Mono PCM (AudioUnit RemoteIO)
        ▼
[ Lock-Free SPSC Ring Buffer ] (4 MB)
        │
        ▼
[ Fast Integer VAD Engine ] (1µs / 20ms frame, 300ms pre-speech, 400ms hangover)
        │ Speech-only audio frames
        ▼
[ Vosk Recognizer Background Worker ]
   ├── Kaldi nnet3 Acoustic Model (AmNnetSimple + final.mdl.cache)
   ├── Memory-Mapped ConstFst Search Graph (mmap, aligned HCLr.fst)
   ├── Online i-Vector Extractor (final.ie.cache covariance acceleration)
   └── Binary Mmap Symbol Table (words.bin, O(1) word lookup)
        │ Partial / Final Text Events
        ▼
[ Spoken Punctuation Normalizer ] (ApplyPunctuation)
        │ Auto space-trim & symbol replacement
        ▼
[ UIKeyboardImpl InsertText / DeleteFromInput ]
```

### Performance & Memory Optimizations

| Metric | Upstream Vosk | DictaKey (Optimized) |
|---|---|---|
| **Subsequent Start Latency (First Word)** | 3.5 – 5.0 s | **~0.5 s** on iPhone 4 (Recognizer reuse) |
| **Cold Model Load Time (iPhone 4)** | 11.4 seconds | **5.6 seconds** (Pre-baked caches & mmap alignment) |
| **Symbol Table Load Time** | 1,500 ms (words.txt) | **1 ms** (mmap `words.bin`) |
| **Heap RAM per Model** | ~110 MB | **~25 MB** (Paged via flash mmap) |
| **Idle RAM Footprint** | Static allocation | **0 MB** (Auto-unloads after 120s idle) |
| **Keyboard Open Overhead** | N/A | **0% CPU / 0 MB RAM** (Pure on-demand loading) |

---

## Building from Source

### Prerequisites
- macOS or Linux with [Theos](https://theos.dev) installed
- iOS 6.1 SDK in `$THEOS/sdks/`
- Clang cross-compiler targeting `armv7`

### Build Base Tweak
```bash
cd tweak
THEOS=~/theos make TARGET_SWIFTC=false package FINALPACKAGE=1 DEBUG=0
```
Output will be generated in `tweak/packages/com.noname122021.dictakey_1.0.0_iphoneos-arm.deb`.

### Baking New Languages
See [baking/README.md](baking/README.md) for instructions on compiling Vosk small models into mmap-compatible binary graphs.

---

## Credits

- **[Vosk](https://github.com/alphacep/vosk-api)** by [Alpha Cephei](https://alphacephei.com/) ([Nikolay Shmyrev](https://github.com/nshmyrev)) — Offline speech recognition library & pre-trained models.
- **[Kaldi](https://github.com/kaldi-asr/kaldi)** by [Daniel Povey](https://github.com/danpovey) & the Kaldi team — Speech recognition toolkit and FST decoders.
- **[Theos](https://github.com/theos/theos)** — Cross-platform build system for iOS tweaks.
- **[Cydia Substrate](https://github.com/saurik/cydia-substrate)** by [Jay Freeman (saurik)](https://github.com/saurik) — Code modification framework and runtime.
- **[invoxiplaygames](https://github.com/invoxiplaygames)** — Legacy iOS root certificates, TLS fixes, and Cydia community tooling.

---

## License

- DictaKey tweak and modifications: MIT License.
- Vosk Engine: Apache License 2.0 (Alpha Cephei Inc.).
- Kaldi ASR: Apache License 2.0.
