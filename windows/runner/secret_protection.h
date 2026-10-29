#ifndef SHOPIKAISS_SECRET_PROTECTION_H_
#define SHOPIKAISS_SECRET_PROTECTION_H_
#include <cstdint>
#include <vector>

// Current Windows user only. This is not a portable backup encryption key.
bool ProtectLocalSecret(const std::vector<uint8_t>& input,
                        std::vector<uint8_t>& output, bool decrypt);
#endif
