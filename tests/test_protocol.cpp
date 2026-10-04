#include <nlohmann/json.hpp>

#include "protocol.h"
#include "test_util.h"

using json = nlohmann::json;

namespace {

// Fake converter: returns "<kana>|<left>|<right>" followed by numbered variants.
bool fake_convert(const zenz::PromptInput& input, int n_best,
                  std::vector<zenz::Candidate>* out, std::string* error) {
    if (input.kana == "fail") {
        *error = "boom";
        return false;
    }
    for (int i = 0; i < n_best; ++i) {
        out->push_back({input.kana + "|" + input.left + "|" + input.right + "|" +
                            std::to_string(i),
                        -static_cast<float>(i)});
    }
    return true;
}

// Fake scorer: scores each text by minus its byte length.
bool fake_score(const zenz::PromptInput& input, const std::vector<std::string>& texts,
                std::vector<float>* out, std::string* error) {
    if (input.kana == "fail") {
        *error = "boom";
        return false;
    }
    for (const std::string& text : texts) {
        out->push_back(-static_cast<float>(text.size()));
    }
    return true;
}

json call(const std::string& line) {
    return json::parse(zenz::handle_line(line, {fake_convert, fake_score}));
}

void test_hello() {
    json hello = json::parse(zenz::hello_line());
    CHECK_EQ(hello["hello"].get<std::string>(), "zenz-server");
    CHECK_EQ(hello["protocol"].get<int>(), zenz::kProtocolVersion);
    CHECK_EQ(hello["version"].get<std::string>(), std::string(zenz::kServerVersion));
}

void test_success() {
    json r = call(R"({"id": 7, "kana": "かな", "left": "左", "right": "右", "n": 2})");
    CHECK_EQ(r["id"].get<int>(), 7);
    CHECK_EQ(r["candidates"].size(), 2u);
    CHECK_EQ(r["candidates"][0].get<std::string>(), "かな|左|右|0");
    CHECK_EQ(r["scores"].size(), 2u);
    CHECK(!r.contains("error"));
}

void test_defaults_and_clamping() {
    json r = call(R"({"id": "a", "kana": "かな"})");
    CHECK_EQ(r["id"].get<std::string>(), "a");
    CHECK_EQ(r["candidates"].size(), 1u);
    CHECK_EQ(r["candidates"][0].get<std::string>(), "かな|||0");

    r = call(R"({"id": 1, "kana": "かな", "left": null, "n": 100})");
    CHECK_EQ(r["candidates"].size(), static_cast<std::size_t>(zenz::kMaxCandidates));
    r = call(R"({"id": 1, "kana": "かな", "n": 0})");
    CHECK_EQ(r["candidates"].size(), 1u);
}

void test_errors() {
    json r = call("not json");
    CHECK(r["id"].is_null());
    CHECK(r.contains("error"));

    r = call("[1, 2]");
    CHECK(r.contains("error"));

    r = call(R"({"id": 3})");
    CHECK_EQ(r["id"].get<int>(), 3);
    CHECK(r.contains("error"));

    r = call(R"({"id": 3, "kana": ""})");
    CHECK(r.contains("error"));

    r = call(R"({"id": 4, "kana": "かな", "left": 1})");
    CHECK(r.contains("error"));

    r = call(R"({"id": 5, "kana": "かな", "n": "2"})");
    CHECK(r.contains("error"));

    r = call(R"({"id": 6, "kana": "fail"})");
    CHECK_EQ(r["id"].get<int>(), 6);
    CHECK_EQ(r["error"].get<std::string>(), "boom");
}

void test_invalid_utf8_in_candidates_is_replaced() {
    auto convert = [](const zenz::PromptInput&, int, std::vector<zenz::Candidate>* out,
                      std::string*) {
        out->push_back({"\xE3\x81", 0.0f});
        return true;
    };
    json r = json::parse(zenz::handle_line(R"({"id": 1, "kana": "a"})", {convert, fake_score}));
    CHECK_EQ(r["candidates"][0].get<std::string>(), "\uFFFD");
}

void test_explicit_convert_op() {
    json r = call(R"({"id": 1, "op": "convert", "kana": "かな"})");
    CHECK_EQ(r["candidates"][0].get<std::string>(), "かな|||0");
}

void test_score() {
    json r = call(R"({"id": 2, "op": "score", "kana": "かな", "candidates": ["a", "bcd", ""]})");
    CHECK_EQ(r["id"].get<int>(), 2);
    CHECK(!r.contains("candidates"));
    CHECK_EQ(r["scores"].size(), 3u);
    CHECK_EQ(r["scores"][0].get<float>(), -1.0f);
    CHECK_EQ(r["scores"][1].get<float>(), -3.0f);
    CHECK_EQ(r["scores"][2].get<float>(), 0.0f);

    r = call(R"({"id": 3, "op": "score", "kana": "かな", "candidates": []})");
    CHECK_EQ(r["scores"].size(), 0u);
}

void test_score_errors() {
    CHECK(call(R"({"id": 1, "op": "nope", "kana": "かな"})").contains("error"));
    CHECK(call(R"({"id": 1, "op": 1, "kana": "かな"})").contains("error"));
    CHECK(call(R"({"id": 1, "op": "score", "kana": "かな"})").contains("error"));
    CHECK(call(R"({"id": 1, "op": "score", "kana": "かな", "candidates": "a"})")
              .contains("error"));
    CHECK(call(R"({"id": 1, "op": "score", "kana": "かな", "candidates": [1]})")
              .contains("error"));
    CHECK(call(R"({"id": 1, "op": "score", "candidates": ["a"]})").contains("error"));

    json many = json::array();
    for (int i = 0; i <= zenz::kMaxScoreCandidates; ++i) {
        many.push_back("a");
    }
    json request = {{"id", 1}, {"op", "score"}, {"kana", "かな"}, {"candidates", many}};
    CHECK(call(request.dump()).contains("error"));

    json r = call(R"({"id": 9, "op": "score", "kana": "fail", "candidates": ["a"]})");
    CHECK_EQ(r["error"].get<std::string>(), "boom");
}

}  // namespace

int main() {
    test_hello();
    test_success();
    test_defaults_and_clamping();
    test_errors();
    test_invalid_utf8_in_candidates_is_replaced();
    test_explicit_convert_op();
    test_score();
    test_score_errors();
    return test_util::finish();
}
