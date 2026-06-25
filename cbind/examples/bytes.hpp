#pragma once
// Shared byte<->string helpers for the examples; libp2p payloads are seq[byte],
// which the generated bindings expose as std::vector<std::uint8_t>.
#include <cstdint>
#include <string>
#include <vector>

inline std::vector<std::uint8_t> toBytes(const std::string& s) {
  return std::vector<std::uint8_t>(s.begin(), s.end());
}

inline std::string toString(const std::vector<std::uint8_t>& b) {
  return std::string(b.begin(), b.end());
}
