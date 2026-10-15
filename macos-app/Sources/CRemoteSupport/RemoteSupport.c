#include "RemoteSupport.h"
#include <stdlib.h>
#include <sys/types.h>

#define SBC_LE 0x00

typedef struct {
    unsigned long flags;
    uint8_t frequency;
    uint8_t blocks;
    uint8_t subbands;
    uint8_t mode;
    uint8_t allocation;
    uint8_t bitpool;
    uint8_t endian;
    void *priv;
    void *priv_alloc_base;
} sbc_t;

extern int sbc_init_msbc(sbc_t *sbc, unsigned long flags);
extern ssize_t sbc_decode(sbc_t *sbc, const void *input, size_t input_len,
                          void *output, size_t output_len, size_t *written);
extern void sbc_finish(sbc_t *sbc);

typedef struct {
    sbc_t codec;
} IPRCSBCDecoder;

IPRCSBCDecoderRef iprc_sbc_decoder_create(void) {
    IPRCSBCDecoder *decoder = calloc(1, sizeof(IPRCSBCDecoder));
    if (decoder == NULL)
        return NULL;
    if (sbc_init_msbc(&decoder->codec, 0) != 0) {
        free(decoder);
        return NULL;
    }
    decoder->codec.endian = SBC_LE;
    return decoder;
}

void iprc_sbc_decoder_destroy(IPRCSBCDecoderRef reference) {
    if (reference == NULL)
        return;
    IPRCSBCDecoder *decoder = reference;
    sbc_finish(&decoder->codec);
    free(decoder);
}

int iprc_sbc_decode_msbc(IPRCSBCDecoderRef reference,
                         const uint8_t *input,
                         size_t input_length,
                         int16_t *output,
                         size_t output_capacity) {
    if (reference == NULL || input == NULL || output == NULL)
        return -1;
    IPRCSBCDecoder *decoder = reference;
    size_t written = 0;
    ssize_t consumed = sbc_decode(&decoder->codec, input, input_length,
                                  output, output_capacity * sizeof(int16_t),
                                  &written);
    if (consumed < 0)
        return (int)consumed;
    return (int)(written / sizeof(int16_t));
}
