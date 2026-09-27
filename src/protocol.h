// JSON Lines protocol between skk-zenz.el and zenz-server.
// See docs/ARCHITECTURE.md for the message format.
#pragma once

#include <functional>
#include <string>
#include <vector>

#include "model.h"
#include "prompt.h"

namespace zenz {

// Bump on incompatible changes; the client checks it against its own version.
constexpr int kProtocolVersion = 1;

// Upper bound for the "n" field of a request.
constexpr int kMaxCandidates = 8;

using ConvertFn = std::function<bool(const PromptInput& input, int n_best,
                                     std::vector<Candidate>* out, std::string* error)>;

// First line the server writes after the model has loaded.
std::string hello_line();

// Parses one request line, runs `convert`, and returns one response line
// (without the trailing newline). Never throws.
std::string handle_line(const std::string& line, const ConvertFn& convert);

}  // namespace zenz
