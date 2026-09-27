// zenz-server: kana-kanji conversion with zenz models.
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

#include "model.h"
#include "prompt.h"

namespace {

void print_usage(const char* argv0) {
    std::cerr
        << "usage: " << argv0 << " [options] --convert KANA\n"
        << "       " << argv0 << " [options] --prompt KANA\n"
        << "\n"
        << "  --convert KANA   convert KANA and print candidates, one per line\n"
        << "  --prompt KANA    print the model prompt for KANA and exit\n"
        << "  --left TEXT      left context\n"
        << "  --right TEXT     right context\n"
        << "  --model PATH     GGUF model (default: $ZENZ_MODEL)\n"
        << "  -n N             number of candidates (default: 1)\n"
        << "  --beam W         beam width (default: max(N, 1), at most 8)\n"
        << "  --threads T      inference threads (default: min(4, CPUs))\n"
        << "  --bench N        run the conversion N times and report the mean time\n"
        << "  --verbose        print llama.cpp logs, scores, and timings to stderr\n";
}

bool parse_int(const char* s, int* out) {
    char* end = nullptr;
    const long v = std::strtol(s, &end, 10);
    if (end == s || *end != '\0' || v <= 0 || v > 1024) {
        return false;
    }
    *out = static_cast<int>(v);
    return true;
}

int default_threads() {
    const unsigned hw = std::thread::hardware_concurrency();
    return hw == 0 ? 4 : static_cast<int>(std::min(hw, 4u));
}

double elapsed_ms(std::chrono::steady_clock::time_point since) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - since)
        .count();
}

}  // namespace

int main(int argc, char** argv) {
    enum class Mode { kNone, kPrompt, kConvert } mode = Mode::kNone;
    zenz::PromptInput input;
    zenz::ModelOptions model_options;
    model_options.n_threads = default_threads();
    zenz::DecodeOptions decode_options;
    int beam = 0;
    int bench = 0;
    std::string model_path;
    if (const char* env = std::getenv("ZENZ_MODEL")) {
        model_path = env;
    }

    for (int i = 1; i < argc; ++i) {
        const char* arg = argv[i];
        const char* value = i + 1 < argc ? argv[i + 1] : nullptr;
        bool ok = true;
        if (std::strcmp(arg, "--verbose") == 0) {
            model_options.verbose = true;
            continue;
        }
        if (value == nullptr) {
            ok = false;
        } else if (std::strcmp(arg, "--convert") == 0) {
            mode = Mode::kConvert;
            input.kana = value;
        } else if (std::strcmp(arg, "--prompt") == 0) {
            mode = Mode::kPrompt;
            input.kana = value;
        } else if (std::strcmp(arg, "--left") == 0) {
            input.left = value;
        } else if (std::strcmp(arg, "--right") == 0) {
            input.right = value;
        } else if (std::strcmp(arg, "--model") == 0) {
            model_path = value;
        } else if (std::strcmp(arg, "-n") == 0) {
            ok = parse_int(value, &decode_options.n_best);
        } else if (std::strcmp(arg, "--beam") == 0) {
            ok = parse_int(value, &beam);
        } else if (std::strcmp(arg, "--bench") == 0) {
            ok = parse_int(value, &bench);
        } else if (std::strcmp(arg, "--threads") == 0) {
            ok = parse_int(value, &model_options.n_threads);
        } else {
            ok = false;
        }
        if (!ok) {
            print_usage(argv[0]);
            return 2;
        }
        ++i;
    }

    const std::string prompt = zenz::build_prompt(input);
    if (mode == Mode::kPrompt) {
        std::cout << prompt << "\n";
        return 0;
    }
    if (mode != Mode::kConvert) {
        print_usage(argv[0]);
        return 2;
    }
    if (model_path.empty()) {
        std::cerr << "error: no model; pass --model or set ZENZ_MODEL\n";
        return 2;
    }

    decode_options.beam_width = beam > 0 ? beam : decode_options.n_best;
    // Kanji output is rarely longer in tokens than the kana input.
    decode_options.max_tokens = static_cast<int>(zenz::utf8_length(input.kana)) + 8;

    const auto t_load = std::chrono::steady_clock::now();
    std::string error;
    auto model = zenz::Model::load(model_path, model_options, &error);
    if (!model) {
        std::cerr << "error: " << error << "\n";
        return 1;
    }
    const double load_ms = elapsed_ms(t_load);

    const auto t_gen = std::chrono::steady_clock::now();
    std::vector<zenz::Candidate> candidates;
    if (!model->generate(prompt, decode_options, &candidates, &error)) {
        std::cerr << "error: " << error << "\n";
        return 1;
    }
    const double gen_ms = elapsed_ms(t_gen);

    if (bench > 0) {
        std::vector<zenz::Candidate> ignored;
        const auto t_bench = std::chrono::steady_clock::now();
        for (int i = 0; i < bench; ++i) {
            model->generate(prompt, decode_options, &ignored, &error);
        }
        std::cerr << "bench: first " << gen_ms << " ms, mean of " << bench << " "
                  << elapsed_ms(t_bench) / bench << " ms\n";
    }

    for (const auto& c : candidates) {
        std::cout << c.text << "\n";
        if (model_options.verbose) {
            std::cerr << "  score " << c.score << "\n";
        }
    }
    if (model_options.verbose) {
        std::cerr << "load " << load_ms << " ms, generate " << gen_ms << " ms\n";
    }
    return 0;
}
