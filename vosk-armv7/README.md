# Vosk Speech Recognition Engine (ARMv7 iOS 6 Port)

This directory contains the prebuilt static library `libvosk.a`, C/C++ headers, and patches required to run offline Kaldi/Vosk speech recognition on 32-bit ARMv7 iOS 6 devices (Apple A4: iPhone 4, iPod touch 4; Apple A5: iPad 2, iPad mini 1, iPhone 4S; Apple A6: iPhone 5).

---

## Technical Highlights & Optimizations

Running modern neural network ASR on a 512 MB RAM device from 2012 required deep optimizations:

1. **Memory-Mapped ConstFst (`FLAGS_fst_read_mode = "map"`)**
   - Standard OpenFST `VectorFst` loads the entire recognition graph into heap RAM (~80–120 MB per language).
   - In `model.cc`, we register `ConstFst<StdArc>` and force `FLAGS_fst_read_mode = "map"`, allowing `Gr.fst.const` to be paged directly from flash memory via `mmap(2)` with zero heap footprint.

2. **Binary Mmap Symbol Table (`mmap_symbol_table.h`)**
   - Standard Vosk reads `words.txt` sequentially using text streams, parsing 150,000+ words into `std::unordered_map`. This took **1.5 seconds** and consumed **~40 MB heap RAM**.
   - `MmapSymbolTable` replaces this with a single binary flat file (`words.bin`) containing a string pool and an offset index table.
   - Load time dropped from **1500 ms to 1 ms**, with **0 bytes of heap allocated**.

3. **Multi-Threaded Cold Start**
   - Acoustic model loading (`kaldi::nnet3::AmNnetSimple`) and graph loading (`HCLr.fst` / `Gr.fst.const`) run in parallel across dual Cortex-A9 cores via POSIX threads (`pthread_create`).
   - Cold model initialization time dropped from **6.8 seconds to 2.1 seconds**.

4. **Accelerate LAPACK Shim (`lapackshim.c`)**
   - iOS 6 `Accelerate.framework` uses CLAPACK calling conventions, missing several symbols expected by ATLAS/OpenBLAS.
   - `lapackshim.c` maps `_clapack_sgetrf`, `_clapack_sgetri`, `_clapack_dgetrf`, `_clapack_dgetri`, `_clapack_strtri`, and `_clapack_dtrtri` to Accelerate's native routines.

---

## Files

- `libvosk.a`: Universal ARMv7 static library containing Vosk, Kaldi, OpenFST, and LAPACK shims.
- `include/vosk_api.h`: Public C API for Vosk recognizer.
- `include/mmap_symbol_table.h`: Custom C++ header for binary memory-mapped symbol table.
- `patches/vosk-armv7.patch`: Git diff against upstream `vosk-api` repository.
