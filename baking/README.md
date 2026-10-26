# Model Baking Tool (`bake_model`)

This tool converts standard Vosk Kaldi speech models into baked, zero-heap memory-mapped models for iOS 6.

---

## What Model Baking Does

1. **ConstFst Compilation (`Gr.fst` $\to$ `Gr.fst.const`)**
   - Strips output symbols table from the FST graph to prevent OpenFST from allocating symbol table copies in RAM.
   - Converts the graph into `fst::ConstFst<fst::StdArc>` format.
   - When loaded by DictaKey with `FLAGS_fst_read_mode = "map"`, the OS kernel maps the file into virtual memory via `mmap(2)` without loading all pages into physical RAM.

2. **Binary Symbol Table Compilation (`words.txt` $\to$ `words.bin`)**
   - Parses the text mapping `word id` into a binary flat file:
     - Header: Magic `0x4D4D5354` ('MMST'), version, count, string pool size.
     - Index table: Array of string pool byte offsets.
     - String pool: Contiguous null-terminated C-strings.
   - Provides $O(1)$ symbol-to-word resolution directly from disk cache.

---

## How to Bake a New Language Model

### 1. Download Vosk Small Model
Download any small model from [alphacephei.com/vosk/models](https://alphacephei.com/vosk/models), for example:
- `vosk-model-small-tr-0.3` (Turkish)
- `vosk-model-small-ja-0.22` (Japanese)

### 2. Compile `bake_model`
```bash
clang++ -O3 -std=c++14 bake_model.cc \
    -I../vosk-armv7/include \
    -L../vosk-armv7 -lvosk \
    -o bake_model
```

### 3. Run Baking
```bash
./bake_model path/to/model/graph
```

### 4. Clean Up Unneeded Files
Once `Gr.fst.const` and `words.bin` are generated:
```bash
rm path/to/model/graph/Gr.fst
rm path/to/model/graph/words.txt
```

### 5. Package for Cydia
Add the language entry to `tools/build_model_debs.py` and run the script to generate an iOS 6 compatible `.deb` package.
