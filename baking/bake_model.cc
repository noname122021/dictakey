#include <iostream>
#include <fstream>
#include <string>
#include <memory>
#include <sys/stat.h>
#include <mach/mach_time.h>
#include <fst/fst.h>
#include <fst/const-fst.h>
#include <fst/register.h>
#include <fst/matcher-fst.h>
#include <fst/extensions/ngram/ngram-fst.h>

#include "vosk-api/src/mmap_symbol_table.h"

namespace fst {
static FstRegisterer<ConstFst<StdArc>> ConstFst_StdArc_registerer;
static FstRegisterer<StdOLabelLookAheadFst> OLabelLookAheadFst_StdArc_registerer;
static FstRegisterer<NGramFst<StdArc>> NGramFst_StdArc_registerer;
}

DECLARE_bool(fst_align);
DECLARE_string(fst_read_mode);

static double now_s(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "Usage: bake_model_ru <graph_dir> [--force]" << std::endl;
        return 1;
    }
    FLAGS_fst_align = true;
    FLAGS_fst_read_mode = "map";

    std::string dir = argv[1];
    bool force = (argc >= 3 && std::string(argv[2]) == "--force");

    std::string g_orig = dir + "/Gr.fst.orig";
    std::string g_fn = dir + "/Gr.fst";
    std::string g_const = dir + "/Gr.fst.const";
    std::string words_bin = dir + "/words.bin";

    struct stat st_const, st_wbin;
    if (!force && stat(g_const.c_str(), &st_const) == 0 && stat(words_bin.c_str(), &st_wbin) == 0) {
        std::cout << "Optimized files already exist. Testing direct read with fst_read_mode=map..." << std::endl;
        double t0 = now_s();
        std::unique_ptr<fst::StdFst> v_g(fst::StdFst::Read(g_const));
        double t_g = now_s() - t0;
        if (!v_g) {
            std::cerr << "Verification failed: cannot read " << g_const << std::endl;
            return 1;
        }
        std::cout << "      Gr.fst.const read in " << t_g << "s (type: " << v_g->Type() << ")" << std::endl;
        std::cout << "      OutputSymbols in Gr.fst.const: " << (v_g->OutputSymbols() ? "PRESENT" : "NULL (correct!)") << std::endl;

        double t1 = now_s();
        std::unique_ptr<MmapSymbolTable> mst(MmapSymbolTable::Load(words_bin));
        double t_w = now_s() - t1;
        if (!mst) {
            std::cerr << "Verification failed: cannot load " << words_bin << std::endl;
            return 1;
        }
        std::cout << "      words.bin mmap loaded in " << (t_w * 1000.0) << "ms (" << mst->NumSymbols() << " symbols)" << std::endl;
        std::cout << "      Symbol 0: '" << mst->Find(0) << "'" << std::endl;
        std::cout << "      Symbol 1: '" << mst->Find(1) << "'" << std::endl;
        std::cout << "      Symbol 100: '" << mst->Find(100) << "'" << std::endl;
        std::string test_word = mst->Find(100);
        std::cout << "      Find('" << test_word << "'): " << mst->Find(test_word) << std::endl;
        return 0;
    }

    // Determine input Gr.fst file
    struct stat st_orig;
    std::string g_input = (stat(g_orig.c_str(), &st_orig) == 0) ? g_orig : g_fn;
    std::cout << "[1/3] Loading source FST from " << g_input << "..." << std::endl;
    double t_load = now_s();
    std::unique_ptr<fst::StdFst> g(fst::StdFst::Read(g_input));
    if (!g) {
        std::cerr << "Failed to read " << g_input << std::endl;
        return 1;
    }
    std::cout << "      Loaded in " << (now_s() - t_load) << "s." << std::endl;

    const fst::SymbolTable *syms = g->OutputSymbols();
    std::unique_ptr<fst::SymbolTable> syms_from_txt;
    if (!syms) {
        std::string words_txt = dir + "/words.txt";
        struct stat st_wtxt;
        if (stat(words_txt.c_str(), &st_wtxt) == 0) {
            std::cout << "      Source FST has no OutputSymbols, loading from " << words_txt << "..." << std::endl;
            syms_from_txt.reset(fst::SymbolTable::ReadText(words_txt));
            syms = syms_from_txt.get();
        }
    }
    if (!syms) {
        std::cerr << "Error: Source FST " << g_input << " does not contain OutputSymbols and " << dir << "/words.txt not found!" << std::endl;
        return 1;
    }
    std::cout << "      Source OutputSymbols count = " << syms->NumSymbols() << std::endl;

    std::cout << "[2/3] Generating " << words_bin << "..." << std::endl;
    double t_wb = now_s();
    if (!MmapSymbolTable::CreateFromSymbolTable(*syms, words_bin)) {
        std::cerr << "Failed to create " << words_bin << std::endl;
        return 1;
    }
    std::cout << "      Generated " << words_bin << " in " << (now_s() - t_wb) << "s." << std::endl;

    std::cout << "[3/3] Converting Gr to stripped ConstFst and writing to " << g_const << "..." << std::endl;
    double t_cg = now_s();
    fst::ConstFst<fst::StdArc> cg(*g);
    std::ofstream g_strm(g_const, std::ios::binary);
    fst::FstWriteOptions wopts(g_const);
    wopts.write_isymbols = false;
    wopts.write_osymbols = false;
    wopts.align = true;
    if (!cg.Write(g_strm, wopts)) {
        std::cerr << "Failed to write " << g_const << std::endl;
        return 1;
    }
    g_strm.close();
    std::cout << "      Wrote " << g_const << " in " << (now_s() - t_cg) << "s." << std::endl;

    std::cout << "\n--- Verification ---" << std::endl;
    double tv0 = now_s();
    std::unique_ptr<fst::StdFst> v_g(fst::StdFst::Read(g_const));
    std::cout << "Verification: Gr.fst.const read in " << (now_s() - tv0) << "s!" << std::endl;
    std::cout << "Verification: OutputSymbols is " << (v_g->OutputSymbols() ? "NOT NULL (unexpected!)" : "NULL (clean!)") << std::endl;

    double tv1 = now_s();
    std::unique_ptr<MmapSymbolTable> mst(MmapSymbolTable::Load(words_bin));
    if (!mst) {
        std::cerr << "Verification failed: cannot load " << words_bin << std::endl;
        return 1;
    }
    std::cout << "Verification: words.bin loaded in " << ((now_s() - tv1) * 1000.0) << "ms!" << std::endl;
    std::cout << "Verification: Total symbols = " << mst->NumSymbols() << std::endl;
    std::cout << "Verification: Symbol 100 = '" << mst->Find(100) << "'" << std::endl;
    return 0;
}
