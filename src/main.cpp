// zenz-server: kana-kanji conversion with zenz models.
#include <cstring>
#include <iostream>
#include <string>

#include "prompt.h"

namespace {

void print_usage(const char* argv0) {
    std::cerr << "usage: " << argv0 << " --prompt KANA [--left TEXT] [--right TEXT]\n"
              << "\n"
              << "  --prompt KANA   print the model prompt for KANA and exit\n";
}

}  // namespace

int main(int argc, char** argv) {
    zenz::PromptInput input;
    bool have_kana = false;
    for (int i = 1; i < argc; ++i) {
        const char* arg = argv[i];
        const bool has_value = i + 1 < argc;
        if (std::strcmp(arg, "--prompt") == 0 && has_value) {
            input.kana = argv[++i];
            have_kana = true;
        } else if (std::strcmp(arg, "--left") == 0 && has_value) {
            input.left = argv[++i];
        } else if (std::strcmp(arg, "--right") == 0 && has_value) {
            input.right = argv[++i];
        } else {
            print_usage(argv[0]);
            return 2;
        }
    }
    if (!have_kana) {
        print_usage(argv[0]);
        return 2;
    }
    std::cout << zenz::build_prompt(input) << "\n";
    return 0;
}
