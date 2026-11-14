/* ML-DSA-65 verification (FIPS 204) for hybrid signatures (§22), from mldsa-native in
 * third_party/mldsa-native: verify only, portable C, no key generation and no randomness. */
#ifndef XIZ_MLDSA_H
#define XIZ_MLDSA_H
#define MLD_CONFIG_PARAMETER_SET 65
#define MLD_CONFIG_NAMESPACE_PREFIX xiz_mldsa65
#define MLD_CONFIG_NO_KEYPAIR_API
#define MLD_CONFIG_NO_SIGN_API
#define MLD_CONFIG_NO_RANDOMIZED_API
#include "mldsa_native.h"
#define XIZ_MLDSA_PUBLICKEY 1952
#define XIZ_MLDSA_SIGNATURE 3309
#endif
