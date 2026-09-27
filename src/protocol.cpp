#include "protocol.h"

#include <algorithm>

#include <nlohmann/json.hpp>

namespace zenz {
namespace {

using json = nlohmann::json;

// Candidates may contain invalid UTF-8 if a beam stops mid-character.
std::string dump(const json& j) {
    return j.dump(-1, ' ', false, json::error_handler_t::replace);
}

std::string error_line(const json& id, const std::string& message) {
    return dump(json{{"id", id}, {"error", message}});
}

// Reads an optional string field. Returns false if present but not a string.
bool optional_string(const json& obj, const char* key, std::string* out) {
    auto it = obj.find(key);
    if (it == obj.end() || it->is_null()) {
        return true;
    }
    if (!it->is_string()) {
        return false;
    }
    *out = it->get<std::string>();
    return true;
}

}  // namespace

std::string hello_line() {
    return dump(json{{"hello", "zenz-server"}, {"protocol", kProtocolVersion}});
}

std::string handle_line(const std::string& line, const ConvertFn& convert) {
    json request = json::parse(line, nullptr, false);
    if (request.is_discarded() || !request.is_object()) {
        return error_line(nullptr, "invalid JSON object");
    }
    const json id = request.value("id", json(nullptr));

    PromptInput input;
    auto kana = request.find("kana");
    if (kana == request.end() || !kana->is_string() || kana->get<std::string>().empty()) {
        return error_line(id, "\"kana\" must be a non-empty string");
    }
    input.kana = kana->get<std::string>();
    if (!optional_string(request, "left", &input.left) ||
        !optional_string(request, "right", &input.right)) {
        return error_line(id, "\"left\" and \"right\" must be strings");
    }

    int n_best = 1;
    auto n = request.find("n");
    if (n != request.end() && !n->is_null()) {
        if (!n->is_number_integer()) {
            return error_line(id, "\"n\" must be an integer");
        }
        n_best = static_cast<int>(std::clamp<long long>(n->get<long long>(), 1, kMaxCandidates));
    }

    std::vector<Candidate> candidates;
    std::string error;
    try {
        if (!convert(input, n_best, &candidates, &error)) {
            return error_line(id, error.empty() ? "conversion failed" : error);
        }
    } catch (const std::exception& e) {
        return error_line(id, e.what());
    }

    json texts = json::array();
    json scores = json::array();
    for (const Candidate& c : candidates) {
        texts.push_back(c.text);
        scores.push_back(c.score);
    }
    return dump(json{{"id", id}, {"candidates", texts}, {"scores", scores}});
}

}  // namespace zenz
