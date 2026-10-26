# DictaKey

<p align="center">
  <img src="assets/icon.png" width="96" height="96" alt="DictaKey Icon" style="border-radius: 20px;"><br>
  <b>Offline Multilingual Voice Dictation for iOS 6</b><br>
  <i>Powered by Vosk Kaldi, OpenFST ConstFst, and Skeuomorphic UIKit Design.</i>
</p>

<p align="center">
  <a href="https://noname122021.github.io/cydia-repo/"><img src="https://img.shields.io/badge/Cydia%20Repo-Add%20Source-orange.svg" alt="Cydia Repo"></a>
  <img src="https://img.shields.io/badge/iOS-6.0%20--%206.1.6-blue.svg" alt="iOS 6.0 - 6.1.6">
  <img src="https://img.shields.io/badge/arch-ARMv7%20(32--bit)-success.svg" alt="ARMv7 32-bit">
  <img src="https://img.shields.io/badge/license-MIT%20%2F%20Apache%202.0-lightgrey.svg" alt="License">
</p>

<p align="center">
  <a href="README.md"><b>English</b></a> • <a href="README.ru.md"><b>Русский</b></a>
</p>

---

## Showcase

| Keyboard Integration (Notes.app) | Settings & Language Management |
|:---:|:---:|
| <img src="assets/keyboard.png" width="460" alt="DictaKey Keyboard"> | <img src="assets/settings.png" width="460" alt="DictaKey Preferences"> |

---

## Overview

**DictaKey** brings modern, completely offline, on-device voice dictation to legacy iOS 6 devices (Apple A5/A6, 32-bit ARMv7). It integrates a skeuomorphic microphone dictation key into the native iOS keyboard, streams audio via a low-latency ring buffer directly to a Kaldi neural acoustic model, and types recognized words into any text field in real time.

DictaKey requires **no internet connection**, **no external servers**, and **no Siri services**. All speech recognition runs entirely on the device processor.

---

## Key Features

- **Native Skeuomorphic Dictation Key**
  - Custom `DKButtonView` drawn using CoreGraphics with authentic iOS 6 etched shadows, specular gradients, and micro-embossed bevels.
  - Real-time RMS audio visualizer waveform rendered inside the microphone glyph while recording.
  - Seamlessly injected into `UIKeyboardImpl` alongside standard keyboard controls on both iPad and iPhone layouts.

- **Multilingual Support & Automatic Input Tracking**
  - Tracks the active keyboard input mode in real time (`ru`, `en`, `uk`, `de`, `fr`, `es`, `it`).
  - Switches models dynamically when toggling between keyboard languages.

- **Spoken Punctuation Engine**
  - Spoken punctuation for 7 languages:
    - **Russian (RU):** `запятая` $\to$ `,`, `двоеточие` $\to$ `:`, `тире` $\to$ ` —`, `дефис` $\to$ `-`.
    - **English (EN):** `comma` $\to$ `,`, `period` $\to$ `.`, `colon` $\to$ `:`, `dash` $\to$ ` —`, `hyphen` $\to$ `-`, `exclamation` $\to$ `!`, `question` $\to$ `?`.
    - **Ukrainian (UK):** `кома` $\to$ `,`, `двокрапка` $\to$ `:`, `тире` $\to$ ` —`, `дефіс` $\to$ `-`.
    - **German (DE), French (FR), Spanish (ES), Italian (IT):** Full native punctuation word mappings.
  - Automatic space trimming (`DeleteBack(1)`) so punctuation attaches cleanly to the preceding word without leading spaces.

- **Dynamic Cydia / APT Model Distribution**
  - Base tweak package is ultra-lightweight (**2.7 MB**).
  - Heavy Kaldi recognition models are distributed as modular Cydia `.deb` packages (`com.noname122021.dictakey-model-<lang>`).
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
4. Search for and install **DictaKey**.
5. Install whichever **DictaKey Model (<Language>)** packages you need.

---

## Supported Devices

- **iPad mini 1st gen** (iOS 6.1.2 / 6.1.3)
- **iPad 2 / iPad 3 / iPad 4** (iOS 6.0 – 6.1.3)
- **iPhone 4S / iPhone 5** (iOS 6.0 – 6.1.4)
- **iPod touch 5th gen** (iOS 6.0 – 6.1.6)

---

## Technical Architecture

```
[ Microphone Audio ] 
        │ 16kHz Mono PCM (AudioUnit RemoteIO)
        ▼
[ Lock-Free SPSC Ring Buffer ] (4 MB)
        │
        ▼
[ Vosk Recognizer Background Worker ]
   ├── Kaldi nnet3 Acoustic Model (AmNnetSimple)
   ├── Memory-Mapped ConstFst Search Graph (mmap, zero heap RAM)
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
| **Cold Model Load Time** | 6.8 seconds | **2.1 seconds** (Parallel pthread loading) |
| **Symbol Table Load Time** | 1,500 ms (words.txt) | **1 ms** (mmap `words.bin`) |
| **Heap RAM per Model** | ~110 MB | **~25 MB** (Paged via flash mmap) |
| **Idle RAM Footprint** | Static allocation | **0 MB** (Auto-unloads after 120s idle) |

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

## Acknowledgements & Credits

- **[Kaldi ASR](https://github.com/kaldi-asr/kaldi)** ([Daniel Povey](https://github.com/danpovey) & the Kaldi Team) — speech recognition framework and FST decoding algorithms.
- **[Vosk API](https://github.com/alphacep/vosk-api)** ([Nikolay Shmyrev](https://github.com/nshmyrev) / [Alpha Cephei](https://alphacephei.com/)) — lightweight offline speech recognition library and pre-trained acoustic models.
- **[invoxiplaygames](https://github.com/invoxiplaygames)** — essential legacy iOS root certificates, TLS fixes, and Cydia community infrastructure.
- **[Jay Freeman (saurik)](https://github.com/saurik)** — [Cydia](https://github.com/saurik/cydia), [MobileSubstrate](https://github.com/saurik/cydia-substrate), and the iOS jailbreak foundation.
- **[Theos](https://github.com/theos/theos)** — modern cross-compilation toolchain for iOS tweak development.

---

## License

- DictaKey tweak and modifications: MIT License.
- Vosk Engine: Apache License 2.0 (Alpha Cephei Inc.).
- Kaldi ASR: Apache License 2.0.
