#ifndef RHIZO_CAMERAD_MJPEG_H
#define RHIZO_CAMERAD_MJPEG_H

// baseline MJPEG to I420 decoder

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct mjpeg_decoder;

// allocate a decoder, or return NULL
struct mjpeg_decoder *mjpeg_decoder_new(void);

void mjpeg_decoder_free(struct mjpeg_decoder *d);

// decode a width x height frame into I420 at dst
int mjpeg_decode(struct mjpeg_decoder *d, const uint8_t *data, size_t size, uint32_t width, uint32_t height,
                 uint8_t *dst, const char **why);

#ifdef __cplusplus
}
#endif

#endif
