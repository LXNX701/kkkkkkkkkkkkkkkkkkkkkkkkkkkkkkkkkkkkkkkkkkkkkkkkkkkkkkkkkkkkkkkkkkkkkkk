#ifndef RESOURCE_VAULT_BRIDGE_H
#define RESOURCE_VAULT_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
const uint8_t *resource_vault_section(size_t *size);
void resource_vault_copy_key(uint8_t out_key[32]);
#ifdef __cplusplus
}
#endif
#endif
