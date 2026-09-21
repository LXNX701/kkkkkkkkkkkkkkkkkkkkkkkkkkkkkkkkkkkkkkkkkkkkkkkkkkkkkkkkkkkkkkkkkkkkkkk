#ifndef PATCH_VAULT_BRIDGE_H
#define PATCH_VAULT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const uint8_t *patch_vault_section(size_t *size);
void patch_vault_copy_key(uint8_t out_key[32]);

#ifdef __cplusplus
}
#endif

#endif
