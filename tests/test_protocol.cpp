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

json call(const std::string& line) {
    return json::parse(zenz::handle_line(line, fake_convert));
}

void test_hello() {
    json hello = json::parse(zenz::hello_line());
    CHECK_EQ(hello["hello"].get<std::string>(), "zenz-server");
    CHECK_EQ(hello["protocol"].get<int>(), zenz::kProtocolVersion);
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
    json r = json::parse(zenz::handle_line(R"({"id": 1, "kana": "a"})", convert));
    CHECK_EQ(r["candidates"][0].get<std::string>(), "\uFFFD");
}

}  // namespace

int main() {
    test_hello();
    test_success();
    test_defaults_and_clamping();
    test_errors();
    test_invalid_utf8_in_candidates_is_replaced();
    return test_util::finish();
}
