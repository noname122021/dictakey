#include <iostream>
#include <fstream>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <fst/fst.h>
#include <fst/register.h>
#include <fst/matcher-fst.h>
#include "vosk_api.h"

namespace fst {
static FstRegisterer<StdOLabelLookAheadFst> OLabelLookAheadFst_StdArc_registerer;
}

static bool align_hclr(const std::string &hclr_path) {
    struct stat st;
    if (stat(hclr_path.c_str(), &st) != 0) {
        std::cerr << "HCLr not found at " << hclr_path << std::endl;
        return false;
    }
    std::cout << "Loading HCLr from " << hclr_path << "..." << std::endl;
    std::unique_ptr<fst::StdFst> fst(fst::StdFst::Read(hclr_path));
    if (!fst) {
        std::cerr << "Failed to read " << hclr_path << std::endl;
        return false;
    }
    std::string tmp_out = hclr_path + ".aligned";
    std::ofstream ostrm(tmp_out, std::ios::binary);
    fst::FstWriteOptions opts(tmp_out);
    opts.align = true;
    std::cout << "Writing 16-byte aligned HCLr to " << tmp_out << "..." << std::endl;
    if (!fst->Write(ostrm, opts)) {
        std::cerr << "Failed to write aligned FST" << std::endl;
        return false;
    }
    ostrm.close();
    rename(tmp_out.c_str(), hclr_path.c_str());
    std::cout << "Successfully replaced " << hclr_path << " with aligned version." << std::endl;
    return true;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "Usage: bake_cache <model_dir>" << std::endl;
        return 1;
    }
    std::string model_dir = argv[1];
    std::string hclr_path = model_dir + "/graph/HCLr.fst";

    // 1. Align HCLr.fst if it exists
    struct stat st_hclr;
    if (stat(hclr_path.c_str(), &st_hclr) == 0) {
        align_hclr(hclr_path);
    }

    // 2. Load model using vosk_model_new, which will auto-generate final.mdl.cache and final.ie.cache
    std::cout << "Calling vosk_model_new(" << model_dir << ")..." << std::endl;
    VoskModel *m = vosk_model_new(model_dir.c_str());
    if (!m) {
        std::cerr << "vosk_model_new failed on " << model_dir << std::endl;
        return 1;
    }
    std::cout << "Model successfully loaded and caches generated!" << std::endl;
    vosk_model_free(m);
    return 0;
}
