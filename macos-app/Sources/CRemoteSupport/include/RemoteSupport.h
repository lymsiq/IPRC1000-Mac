#ifndef IPRC_REMOTE_SUPPORT_H
#define IPRC_REMOTE_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

typedef void *IPRCSBCDecoderRef;

IPRCSBCDecoderRef iprc_sbc_decoder_create(void);
void iprc_sbc_decoder_destroy(IPRCSBCDecoderRef decoder);

/* Decodes one 57-byte mSBC frame. Returns mono PCM sample count, or < 0. */
int iprc_sbc_decode_msbc(IPRCSBCDecoderRef decoder,
                         const uint8_t *input,
                         size_t input_length,
                         int16_t *output,
                         size_t output_capacity);

#endif
