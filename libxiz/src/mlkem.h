/* ML-KEM-768 decapsulation (FIPS 203) for X-Wing recipients (§17), from mlkem-native in
 * third_party/mlkem-native: portable C, deterministic key expansion and decapsulation only. */
#ifndef XIZ_MLKEM_H
#define XIZ_MLKEM_H
#define MLK_CONFIG_PARAMETER_SET 768
#define MLK_CONFIG_NAMESPACE_PREFIX xiz_mlkem768
#define MLK_CONFIG_NO_ENCAPS_API
#define MLK_CONFIG_NO_RANDOMIZED_API
#include "mlkem_native.h"
#define XIZ_MLKEM_PUBLICKEY 1184
#define XIZ_MLKEM_SECRETKEY 2400
#define XIZ_MLKEM_CIPHERTEXT 1088

/* FIPS 202 from the same library (internal symbols of mlkem-native, exported by mlkem.c). */
void xiz_mlkem768_shake256(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen);
void xiz_mlkem768_sha3_256(uint8_t out[32], const uint8_t *in, size_t inlen);
#endif
