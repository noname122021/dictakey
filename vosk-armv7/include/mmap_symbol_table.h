#pragma once

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <string>
#include <memory>
#include <vector>
#include <algorithm>
#include <fstream>
#include <iostream>

#include <fst/fst.h>
#include <fst/symbol-table.h>

struct WordsBinHeader {
    uint32_t magic;          // 0x574F5244 ("WORD")
    uint32_t version;        // 1
    uint32_t num_symbols;    // count
    uint32_t string_bytes;   // string pool size in bytes
    uint32_t offsets_offset; // byte offset to uint32_t offsets[num_symbols]
    uint32_t sorted_offset;  // byte offset to uint32_t sorted_indices[num_symbols]
    uint32_t strings_offset; // byte offset to null-terminated UTF-8 strings
    uint32_t reserved[9];    // 0
};

class MmapSymbolTable : public fst::SymbolTable {
private:
    struct Mapping {
        void *addr = MAP_FAILED;
        size_t size = 0;
        int fd = -1;
        ~Mapping() {
            if (addr != MAP_FAILED && addr != nullptr) {
                munmap(addr, size);
            }
            if (fd >= 0) {
                close(fd);
            }
        }
    };

    std::shared_ptr<Mapping> mapping_;
    const WordsBinHeader *header_ = nullptr;
    const uint32_t *offsets_ = nullptr;
    const uint32_t *sorted_indices_ = nullptr;
    const char *strings_ = nullptr;
    size_t num_symbols_ = 0;

public:
    MmapSymbolTable() : fst::SymbolTable("words.bin") {}

    static bool CreateFromSymbolTable(const fst::SymbolTable &syms, const std::string &out_path) {
        size_t n = syms.NumSymbols();
        if (n == 0) return false;

        std::vector<std::string> words(n);
        for (fst::SymbolTableIterator it(syms); !it.Done(); it.Next()) {
            int64 key = it.Value();
            if (key < 0 || static_cast<size_t>(key) >= n) {
                std::cerr << "Non-contiguous key in SymbolTable: " << key << " (max " << n << ")" << std::endl;
                return false;
            }
            words[key] = it.Symbol();
        }

        std::vector<uint32_t> offsets(n);
        std::vector<char> str_pool;
        str_pool.reserve(n * 16);

        for (size_t i = 0; i < n; ++i) {
            offsets[i] = static_cast<uint32_t>(str_pool.size());
            const std::string &w = words[i];
            str_pool.insert(str_pool.end(), w.c_str(), w.c_str() + w.length() + 1);
        }

        std::vector<uint32_t> sorted_indices(n);
        for (size_t i = 0; i < n; ++i) sorted_indices[i] = static_cast<uint32_t>(i);
        std::sort(sorted_indices.begin(), sorted_indices.end(), [&](uint32_t a, uint32_t b) {
            return strcmp(str_pool.data() + offsets[a], str_pool.data() + offsets[b]) < 0;
        });

        WordsBinHeader hdr;
        memset(&hdr, 0, sizeof(hdr));
        hdr.magic = 0x574F5244;
        hdr.version = 1;
        hdr.num_symbols = static_cast<uint32_t>(n);
        hdr.string_bytes = static_cast<uint32_t>(str_pool.size());
        hdr.offsets_offset = sizeof(hdr);
        hdr.sorted_offset = hdr.offsets_offset + static_cast<uint32_t>(n * sizeof(uint32_t));
        hdr.strings_offset = hdr.sorted_offset + static_cast<uint32_t>(n * sizeof(uint32_t));

        std::ofstream out(out_path, std::ios::binary);
        if (!out) return false;
        out.write(reinterpret_cast<const char *>(&hdr), sizeof(hdr));
        out.write(reinterpret_cast<const char *>(offsets.data()), offsets.size() * sizeof(uint32_t));
        out.write(reinterpret_cast<const char *>(sorted_indices.data()), sorted_indices.size() * sizeof(uint32_t));
        out.write(str_pool.data(), str_pool.size());
        out.flush();
        return out.good();
    }

    static MmapSymbolTable *Load(const std::string &path) {
        int fd = open(path.c_str(), O_RDONLY);
        if (fd < 0) return nullptr;
        struct stat st;
        if (fstat(fd, &st) < 0 || st.st_size < static_cast<off_t>(sizeof(WordsBinHeader))) {
            close(fd);
            return nullptr;
        }
        void *addr = mmap(nullptr, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
        if (addr == MAP_FAILED) {
            close(fd);
            return nullptr;
        }
        const WordsBinHeader *hdr = static_cast<const WordsBinHeader *>(addr);
        if (hdr->magic != 0x574F5244 || hdr->version != 1) {
            munmap(addr, st.st_size);
            close(fd);
            return nullptr;
        }

        std::unique_ptr<MmapSymbolTable> tbl(new MmapSymbolTable());
        tbl->mapping_ = std::make_shared<Mapping>();
        tbl->mapping_->addr = addr;
        tbl->mapping_->size = st.st_size;
        tbl->mapping_->fd = fd;
        tbl->header_ = hdr;
        const char *base = static_cast<const char *>(addr);
        tbl->offsets_ = reinterpret_cast<const uint32_t *>(base + hdr->offsets_offset);
        tbl->sorted_indices_ = reinterpret_cast<const uint32_t *>(base + hdr->sorted_offset);
        tbl->strings_ = base + hdr->strings_offset;
        tbl->num_symbols_ = hdr->num_symbols;
        return tbl.release();
    }

    virtual ~MmapSymbolTable() override {}

    virtual SymbolTable *Copy() const override {
        MmapSymbolTable *copy = new MmapSymbolTable();
        copy->mapping_ = this->mapping_;
        copy->header_ = this->header_;
        copy->offsets_ = this->offsets_;
        copy->sorted_indices_ = this->sorted_indices_;
        copy->strings_ = this->strings_;
        copy->num_symbols_ = this->num_symbols_;
        return copy;
    }

    virtual std::string Find(int64 key) const override {
        if (key < 0 || static_cast<size_t>(key) >= num_symbols_) return "";
        uint32_t off = offsets_[key];
        return std::string(strings_ + off);
    }

    virtual int64 Find(const std::string &symbol) const override {
        if (num_symbols_ == 0) return fst::kNoSymbol;
        const char *target = symbol.c_str();
        int l = 0, r = static_cast<int>(num_symbols_) - 1;
        while (l <= r) {
            int m = l + (r - l) / 2;
            uint32_t key = sorted_indices_[m];
            const char *cand = strings_ + offsets_[key];
            int cmp = strcmp(target, cand);
            if (cmp == 0) return key;
            if (cmp < 0) r = m - 1;
            else l = m + 1;
        }
        return fst::kNoSymbol;
    }

    virtual bool Member(int64 key) const override {
        return (key >= 0 && static_cast<size_t>(key) < num_symbols_);
    }

    virtual bool Member(const std::string &symbol) const override {
        return Find(symbol) != fst::kNoSymbol;
    }

    virtual size_t NumSymbols() const override {
        return num_symbols_;
    }

    virtual int64 GetNthKey(ssize_t pos) const override {
        if (pos < 0 || static_cast<size_t>(pos) >= num_symbols_) return fst::kNoSymbol;
        return pos;
    }

    virtual int64 AvailableKey() const override {
        return num_symbols_;
    }

    virtual const std::string &Name() const override {
        static const std::string kName = "words.bin";
        return kName;
    }
};
