#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input-event-codes.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-data-control-unstable-v1-client-protocol.h"
#include "ext-data-control-v1-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include "xdg-output-unstable-v1-client-protocol.h"

#define MAX_PAYLOAD ((size_t)8 * 1024 * 1024)
#define MAX_LINE (((MAX_PAYLOAD / 3) + 1) * 4 + 4096)

#define PAD_SIZE 64

static const char b64_alphabet[] =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// encode bytes as base64 text
static char *b64_encode(const unsigned char *data, size_t len) {
  size_t outlen = 4 * ((len + 2) / 3);
  char *out = malloc(outlen + 1);
  if (!out) return NULL;
  size_t i = 0, j = 0;
  while (i + 3 <= len) {
    uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1] << 8) | data[i + 2];
    out[j++] = b64_alphabet[(v >> 18) & 0x3f];
    out[j++] = b64_alphabet[(v >> 12) & 0x3f];
    out[j++] = b64_alphabet[(v >> 6) & 0x3f];
    out[j++] = b64_alphabet[v & 0x3f];
    i += 3;
  }
  size_t rem = len - i;
  if (rem == 1) {
    uint32_t v = (uint32_t)data[i] << 16;
    out[j++] = b64_alphabet[(v >> 18) & 0x3f];
    out[j++] = b64_alphabet[(v >> 12) & 0x3f];
    out[j++] = '=';
    out[j++] = '=';
  } else if (rem == 2) {
    uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1] << 8);
    out[j++] = b64_alphabet[(v >> 18) & 0x3f];
    out[j++] = b64_alphabet[(v >> 12) & 0x3f];
    out[j++] = b64_alphabet[(v >> 6) & 0x3f];
    out[j++] = '=';
  }
  out[j] = '\0';
  return out;
}

// return the value of a base64 character, or -1
static int b64_val(unsigned char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

// decode a strict base64 string
static unsigned char *b64_decode(const char *in, size_t slen, size_t *outlen) {
  if (slen == 0) {
    *outlen = 0;
    return malloc(1);
  }
  if (slen % 4 != 0) return NULL;
  size_t pad = 0;
  if (in[slen - 1] == '=') pad++;
  if (in[slen - 2] == '=') pad++;
  unsigned char *out = malloc((slen / 4) * 3 - pad);
  if (!out) return NULL;
  size_t oi = 0;
  for (size_t i = 0; i < slen; i += 4) {
    int is_pad2 = in[i + 2] == '=' && i + 4 == slen;
    int is_pad3 = in[i + 3] == '=' && i + 4 == slen;
    if ((in[i + 2] == '=') != is_pad2 || (in[i + 3] == '=') != is_pad3 || (is_pad2 && !is_pad3)) {
      free(out);
      return NULL;
    }
    int v0 = b64_val(in[i]);
    int v1 = b64_val(in[i + 1]);
    int v2 = is_pad2 ? 0 : b64_val(in[i + 2]);
    int v3 = is_pad3 ? 0 : b64_val(in[i + 3]);
    if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0) {
      free(out);
      return NULL;
    }
    uint32_t v = ((uint32_t)v0 << 18) | ((uint32_t)v1 << 12) | ((uint32_t)v2 << 6) | (uint32_t)v3;
    out[oi++] = (v >> 16) & 0xff;
    if (!is_pad2) out[oi++] = (v >> 8) & 0xff;
    if (!is_pad3) out[oi++] = v & 0xff;
  }
  *outlen = oi;
  return out;
}

// check base64 encoding and decoding round trips
static int run_selftest_base64(void) {
  unsigned char data[4096];
  for (size_t i = 0; i < sizeof(data); i++) data[i] = (unsigned char)i;
  size_t lens[] = {0, 1, 2, 3, 4, 5, 6, 7, 255, 256, 257, 4095, 4096};
  for (size_t k = 0; k < sizeof(lens) / sizeof(lens[0]); k++) {
    size_t len = lens[k];
    char *enc = b64_encode(data, len);
    if (!enc) { fprintf(stderr, "selftest: encode failed at len %zu\n", len); return 1; }
    size_t declen;
    unsigned char *dec = b64_decode(enc, strlen(enc), &declen);
    if (!dec) { fprintf(stderr, "selftest: decode failed at len %zu\n", len); free(enc); return 1; }
    if (declen != len || (len && memcmp(dec, data, len) != 0)) {
      fprintf(stderr, "selftest: round trip mismatch at len %zu (got %zu bytes)\n", len, declen);
      free(enc); free(dec);
      return 1;
    }
    free(enc);
    free(dec);
  }
  fprintf(stderr, "selftest: base64 round trip OK (%zu lengths)\n", sizeof(lens) / sizeof(lens[0]));
  return 0;
}

// mime types of a selection offer
struct offer_state {
  void *offer;
  char **mimes;
  size_t n_mimes;
  size_t cap_mimes;
};

// selection offered to the compositor
struct outgoing {
  void *src;
  char *mime;
  unsigned char *data;
  size_t len;
  int held_fd;
  struct outgoing *next;
};

// mime types of a drag offer
struct dnd_offer {
  struct wl_data_offer *offer;
  char **mimes;
  size_t n_mimes;
  size_t cap_mimes;
};

// payload for a host-initiated drag
struct dnd_payload {
  char *mime;
  unsigned char *data;
  size_t len;
};

// surface for drag and drop
struct pad {
  struct wl_surface *surface;
  struct zwlr_layer_surface_v1 *layer_surface;
  struct xdg_surface *xdg_surface;
  struct xdg_toplevel *xdg_toplevel;
  struct wl_shm_pool *pool;
  struct wl_buffer *buffer;
};

static struct wl_display *display;
static struct wl_seat *seat;
static void *manager;
static void *device;
static int dc_ext;
static struct zwlr_data_control_manager_v1 *wlr_manager;
static struct ext_data_control_manager_v1 *ext_manager;

// destroy a data control offer
static void dc_offer_destroy(void *offer) {
  if (dc_ext) ext_data_control_offer_v1_destroy(offer);
  else zwlr_data_control_offer_v1_destroy(offer);
}
// ask a data control offer to write a mime type to a descriptor
static void dc_offer_receive(void *offer, const char *mime, int fd) {
  if (dc_ext) ext_data_control_offer_v1_receive(offer, mime, fd);
  else zwlr_data_control_offer_v1_receive(offer, mime, fd);
}
// create a data control source
static void *dc_create_source(void) {
  if (dc_ext) return ext_data_control_manager_v1_create_data_source(manager);
  return zwlr_data_control_manager_v1_create_data_source(manager);
}
// add a mime type to a data control source
static void dc_source_offer(void *src, const char *mime) {
  if (dc_ext) ext_data_control_source_v1_offer(src, mime);
  else zwlr_data_control_source_v1_offer(src, mime);
}
// destroy a data control source
static void dc_source_destroy(void *src) {
  if (dc_ext) ext_data_control_source_v1_destroy(src);
  else zwlr_data_control_source_v1_destroy(src);
}
// set the data control selection to a source
static void dc_set_selection(void *src) {
  if (dc_ext) ext_data_control_device_v1_set_selection(device, src);
  else zwlr_data_control_device_v1_set_selection(device, src);
}
static struct offer_state *current_selection;
static unsigned long selection_gen;
#define PASSWORD_HINT_MIME "x-kde-passwordManagerHint"
static struct outgoing *outgoing_head;
static int should_quit;
static volatile sig_atomic_t term_signal;
static sigset_t pump_sigmask;
static int releasing;

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_output *output;
static uint32_t output_width, output_height;
static int output_have_mode;
#define MAX_OUTPUTS 16
struct output_rect {
  struct wl_output *wo;
  struct zxdg_output_v1 *xo;
  int32_t x, y, w, h;
  int known;
};
static struct output_rect outputs[MAX_OUTPUTS];
static size_t n_outputs;
static struct zxdg_output_manager_v1 *xdg_output_manager;
static struct zwlr_layer_shell_v1 *layer_shell;
static struct xdg_wm_base *wm_base;
static int pad_mode_xdg;
static struct zwlr_virtual_pointer_manager_v1 *vp_manager;
static struct zwlr_virtual_pointer_v1 *vp_pointer;
static int vp_on_output;
static struct wl_data_device_manager *data_manager;
static struct wl_data_device *dnd_device;
static struct wl_pointer *pointer;
static uint32_t press_serial;
static int have_press_serial;
static uint32_t last_sent_abs_x, last_sent_abs_y;
static int pad_abs_known;
static uint32_t pad_abs_x, pad_abs_y;

static struct pad *pad;
static int pad_configured;
static int dragpad_persistent;
static struct dnd_offer *current_dnd_offer;
static int dnd_source_active;
static struct dnd_payload *dnd_payload;

static int32_t output_x, output_y;
static int pointer_on_pad;
static unsigned pad_enters;
static struct dnd_payload *armed_drag;

static int selection_via_pad;
static struct wl_keyboard *keyboard;
static int pad_has_keyboard;
static uint32_t keyboard_serial;
static struct dnd_offer *pad_selection;
// selection offered through the pad
struct pad_outgoing {
  struct wl_data_source *src;
  unsigned char *data;
  size_t len;
  struct pad_outgoing *next;
};
static struct pad_outgoing *pad_outgoing_head;

static int wl_pump(int extra_fd, short extra_events, short *extra_revents, int timeout_ms);
static void emit_conn_error(void);
static unsigned char *grow_buf(unsigned char *buf, size_t *cap, size_t need);

// free an offer state and its mime types
static void free_offer_state(struct offer_state *s, int destroy_proxy) {
  if (!s) return;
  for (size_t i = 0; i < s->n_mimes; i++) free(s->mimes[i]);
  free(s->mimes);
  if (destroy_proxy && s->offer) dc_offer_destroy(s->offer);
  free(s);
}

// return whether an offer lists a mime type
static int mime_in_list(const struct offer_state *s, const char *mime) {
  if (!s) return 0;
  for (size_t i = 0; i < s->n_mimes; i++)
    if (!strcmp(s->mimes[i], mime)) return 1;
  return 0;
}

// free a drag offer and its mime types
static void free_dnd_offer(struct dnd_offer *s, int destroy_proxy) {
  if (!s) return;
  for (size_t i = 0; i < s->n_mimes; i++) free(s->mimes[i]);
  free(s->mimes);
  if (destroy_proxy && s->offer) wl_data_offer_destroy(s->offer);
  free(s);
}

// return the monotonic time in milliseconds
static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

// return the pad's output rectangle
static struct output_rect *pad_output_rect(void) {
  for (size_t i = 0; i < n_outputs; i++)
    if (outputs[i].wo == output && outputs[i].known) return &outputs[i];
  return NULL;
}

// return the pointer motion box
static void vp_box(int64_t *bx, int64_t *by, int64_t *bw, int64_t *bh) {
  struct output_rect *po = pad_output_rect();
  if (vp_on_output && po) {
    *bx = po->x; *by = po->y; *bw = po->w; *bh = po->h;
    return;
  }
  int64_t x0 = 0, y0 = 0, x1 = 0, y1 = 0;
  int any = 0;
  for (size_t i = 0; i < n_outputs; i++) {
    if (!outputs[i].known) continue;
    struct output_rect *o = &outputs[i];
    if (!any || o->x < x0) x0 = o->x;
    if (!any || o->y < y0) y0 = o->y;
    if (!any || o->x + o->w > x1) x1 = o->x + o->w;
    if (!any || o->y + o->h > y1) y1 = o->y + o->h;
    any = 1;
  }
  if (!any) {
    x0 = output_x; y0 = output_y;
    x1 = x0 + output_width; y1 = y0 + output_height;
  }
  *bx = x0; *by = y0; *bw = x1 - x0; *bh = y1 - y0;
}

// check a point against the pointer box
static int vp_reachable(long x, long y, char *why, size_t n) {
  int64_t bx, by, bw, bh;
  vp_box(&bx, &by, &bw, &bh);
  if (bw > 0 && bh > 0 && x >= bx && y >= by && x < bx + bw && y < by + bh) return 1;
  if (why)
    snprintf(why, n, "%ld,%ld lies outside the %s %lldx%lld at %lld,%lld", x, y,
             vp_on_output ? "pad's output" : "output layout", (long long)bw, (long long)bh,
             (long long)bx, (long long)by);
  return 0;
}

// move the virtual pointer to a layout point
static void vp_move_absolute(uint32_t x, uint32_t y) {
  int64_t bx, by, bw, bh;
  vp_box(&bx, &by, &bw, &bh);
  int64_t rx = (int64_t)x - bx, ry = (int64_t)y - by;
  if (rx < 0) rx = 0;
  if (ry < 0) ry = 0;
  if (bw <= 0 || bh <= 0) { bw = 1; bh = 1; rx = 0; ry = 0; }
  zwlr_virtual_pointer_v1_motion_absolute(vp_pointer, now_ms(), (uint32_t)rx, (uint32_t)ry,
                                          (uint32_t)bw, (uint32_t)bh);
  last_sent_abs_x = x;
  last_sent_abs_y = y;
}

// record the pad output's layout position
static void on_output_geometry(void *data, struct wl_output *out, int32_t x, int32_t y,
                               int32_t phys_w, int32_t phys_h, int32_t subpixel,
                               const char *make, const char *model, int32_t transform) {
  (void)data; (void)phys_w; (void)phys_h;
  (void)subpixel; (void)make; (void)model; (void)transform;
  if (out != output || xdg_output_manager) return;
  output_x = x;
  output_y = y;
}
// store the current mode size of the output
static void on_output_mode(void *data, struct wl_output *out, uint32_t flags,
                           int32_t width, int32_t height, int32_t refresh) {
  (void)data; (void)refresh;
  if (out != output) return;
  if (!(flags & WL_OUTPUT_MODE_CURRENT)) return;
  output_width = (uint32_t)width;
  output_height = (uint32_t)height;
  output_have_mode = 1;
}
// ignore the output done event
static void on_output_done(void *data, struct wl_output *out) {
  (void)data; (void)out;
}
// ignore the output scale event
static void on_output_scale(void *data, struct wl_output *out, int32_t factor) {
  (void)data; (void)out; (void)factor;
}
static const struct wl_output_listener output_listener = {
  .geometry = on_output_geometry, .mode = on_output_mode,
  .done = on_output_done, .scale = on_output_scale,
};

// store the logical position of the output
static void on_xdg_output_position(void *data, struct zxdg_output_v1 *xo, int32_t x, int32_t y) {
  (void)xo;
  struct output_rect *o = data;
  o->x = x;
  o->y = y;
  if (o->wo == output) { output_x = x; output_y = y; }
}
// store the logical size of the output
static void on_xdg_output_size(void *data, struct zxdg_output_v1 *xo, int32_t w, int32_t h) {
  (void)xo;
  struct output_rect *o = data;
  o->w = w;
  o->h = h;
  o->known = w > 0 && h > 0;
}
static void on_xdg_output_done(void *data, struct zxdg_output_v1 *xo) { (void)data; (void)xo; }
// ignore the output name event
static void on_xdg_output_name(void *data, struct zxdg_output_v1 *xo, const char *name) {
  (void)data; (void)xo; (void)name;
}
// ignore the output description event
static void on_xdg_output_description(void *data, struct zxdg_output_v1 *xo, const char *d) {
  (void)data; (void)xo; (void)d;
}
static const struct zxdg_output_v1_listener xdg_output_listener = {
  .logical_position = on_xdg_output_position, .logical_size = on_xdg_output_size,
  .done = on_xdg_output_done, .name = on_xdg_output_name,
  .description = on_xdg_output_description,
};

// request an xdg-output for each wl_output
static void watch_output_rects(void) {
  if (!xdg_output_manager) return;
  for (size_t i = 0; i < n_outputs; i++) {
    if (outputs[i].xo) continue;
    outputs[i].xo = zxdg_output_manager_v1_get_xdg_output(xdg_output_manager, outputs[i].wo);
    zxdg_output_v1_add_listener(outputs[i].xo, &xdg_output_listener, &outputs[i]);
  }
}

static const struct wl_seat_listener seat_listener;

// answer a ping from the window manager
static void on_wm_base_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
  (void)data;
  xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = { .ping = on_wm_base_ping };

static int cap_clipboard = 0, cap_drag = 0, cap_pointer = 0;

// search the list for a capability
static int caps_has(const char *list, const char *want) {
  size_t n = strlen(want);
  for (const char *p = list; *p; ) {
    const char *end = strchr(p, ',');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    if (len == n && !strncmp(p, want, n)) return 1;
    if (!end) break;
    p = end + 1;
  }
  return 0;
}

// bind Wayland globals from the registry
static void on_global(void *data, struct wl_registry *reg, uint32_t name,
                      const char *iface, uint32_t version) {
  (void)data;
  if (!strcmp(iface, wl_seat_interface.name)) {
    seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    wl_seat_add_listener(seat, &seat_listener, NULL);
  } else if (!strcmp(iface, zwlr_data_control_manager_v1_interface.name)) {
    if (!cap_clipboard) return;
    uint32_t bind_version = version < 2 ? version : 2;
    wlr_manager = wl_registry_bind(reg, name, &zwlr_data_control_manager_v1_interface, bind_version);
  } else if (!strcmp(iface, ext_data_control_manager_v1_interface.name)) {
    if (!cap_clipboard) return;
    ext_manager = wl_registry_bind(reg, name, &ext_data_control_manager_v1_interface, 1);
  } else if (!strcmp(iface, wl_compositor_interface.name)) {
    compositor = wl_registry_bind(reg, name, &wl_compositor_interface,
                                  version < 4 ? version : 4);
  } else if (!strcmp(iface, wl_shm_interface.name)) {
    shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
  } else if (!strcmp(iface, wl_output_interface.name)) {
    uint32_t bind_version = version < 2 ? version : 2;
    output = wl_registry_bind(reg, name, &wl_output_interface, bind_version);
    wl_output_add_listener(output, &output_listener, NULL);
    if (n_outputs < MAX_OUTPUTS) {
      outputs[n_outputs++].wo = output;
      watch_output_rects();
    }
  } else if (!strcmp(iface, zxdg_output_manager_v1_interface.name)) {
    xdg_output_manager = wl_registry_bind(reg, name, &zxdg_output_manager_v1_interface,
                                          version < 2 ? version : 2);
    watch_output_rects();
  } else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name)) {
    if (!cap_drag) return;
    layer_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, 1);
  } else if (!strcmp(iface, xdg_wm_base_interface.name)) {
    wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
  } else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name)) {
    if (!cap_pointer) return;
    vp_manager = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface,
                                  version < 2 ? version : 2);
  } else if (!strcmp(iface, wl_data_device_manager_interface.name)) {
    if (!cap_drag) return;
    uint32_t bind_version = version < 3 ? version : 3;
    data_manager = wl_registry_bind(reg, name, &wl_data_device_manager_interface, bind_version);
  }
}
// ignore the removal of a global
static void on_global_remove(void *d, struct wl_registry *r, uint32_t n) {
  (void)d; (void)r; (void)n;
}
static const struct wl_registry_listener registry_listener = {
  .global = on_global, .global_remove = on_global_remove,
};

// append a mime type to the pending offer
static void dc_on_offer_mime(void *data, const char *mime_type) {
  struct offer_state *pending = data;
  if (pending->n_mimes == pending->cap_mimes) {
    pending->cap_mimes = pending->cap_mimes ? pending->cap_mimes * 2 : 4;
    pending->mimes = realloc(pending->mimes, pending->cap_mimes * sizeof(char *));
  }
  pending->mimes[pending->n_mimes++] = strdup(mime_type);
}
// add a mime type to a wlr data control offer
static void wlr_on_offer_mime(void *data, struct zwlr_data_control_offer_v1 *offer, const char *mime_type) {
  (void)offer;
  dc_on_offer_mime(data, mime_type);
}
// add a mime type to an ext data control offer
static void ext_on_offer_mime(void *data, struct ext_data_control_offer_v1 *offer, const char *mime_type) {
  (void)offer;
  dc_on_offer_mime(data, mime_type);
}
static const struct zwlr_data_control_offer_v1_listener wlr_offer_listener = {
  .offer = wlr_on_offer_mime,
};
static const struct ext_data_control_offer_v1_listener ext_offer_listener = {
  .offer = ext_on_offer_mime,
};

// start tracking a new data control offer
static void dc_on_data_offer(void *id) {
  struct offer_state *pending = calloc(1, sizeof(*pending));
  pending->offer = id;
  if (dc_ext) ext_data_control_offer_v1_add_listener(id, &ext_offer_listener, pending);
  else zwlr_data_control_offer_v1_add_listener(id, &wlr_offer_listener, pending);
}
// replace the current selection with a new data control offer
static void dc_on_selection(void *id) {
  selection_gen++;
  free_offer_state(current_selection, 1);
  current_selection = NULL;
  if (releasing) {
    if (id) free_offer_state(wl_proxy_get_user_data(id), 1);
    return;
  }
  if (!id) {
    printf("selection none\n");
    fflush(stdout);
    return;
  }
  current_selection = wl_proxy_get_user_data(id);
  printf("selection");
  for (size_t i = 0; i < current_selection->n_mimes; i++) printf(" %s", current_selection->mimes[i]);
  printf("\n");
  fflush(stdout);
}
// free the primary selection offer
static void dc_on_primary_selection(void *id) {
  if (id) free_offer_state(wl_proxy_get_user_data(id), 1);
}
// report that the data control device finished and stop
static void dc_on_finished(void) {
  printf("error data control device finished\n");
  fflush(stdout);
  should_quit = 1;
}
// handle a new wlr data control offer
static void wlr_on_data_offer(void *data, struct zwlr_data_control_device_v1 *dev,
                              struct zwlr_data_control_offer_v1 *id) {
  (void)data; (void)dev;
  dc_on_data_offer(id);
}
// handle a wlr data control selection
static void wlr_on_selection(void *data, struct zwlr_data_control_device_v1 *dev,
                             struct zwlr_data_control_offer_v1 *id) {
  (void)data; (void)dev;
  dc_on_selection(id);
}
// handle a wlr data control primary selection
static void wlr_on_primary_selection(void *data, struct zwlr_data_control_device_v1 *dev,
                                     struct zwlr_data_control_offer_v1 *id) {
  (void)data; (void)dev;
  dc_on_primary_selection(id);
}
// handle the wlr data control device finishing
static void wlr_on_finished(void *data, struct zwlr_data_control_device_v1 *dev) {
  (void)data; (void)dev;
  dc_on_finished();
}
static const struct zwlr_data_control_device_v1_listener wlr_device_listener = {
  .data_offer = wlr_on_data_offer,
  .selection = wlr_on_selection,
  .finished = wlr_on_finished,
  .primary_selection = wlr_on_primary_selection,
};
// handle a new ext data control offer
static void ext_on_data_offer(void *data, struct ext_data_control_device_v1 *dev,
                              struct ext_data_control_offer_v1 *id) {
  (void)data; (void)dev;
  dc_on_data_offer(id);
}
// handle an ext data control selection
static void ext_on_selection(void *data, struct ext_data_control_device_v1 *dev,
                             struct ext_data_control_offer_v1 *id) {
  (void)data; (void)dev;
  dc_on_selection(id);
}
// handle an ext data control primary selection
static void ext_on_primary_selection(void *data, struct ext_data_control_device_v1 *dev,
                                     struct ext_data_control_offer_v1 *id) {
  (void)data; (void)dev;
  dc_on_primary_selection(id);
}
// handle the ext data control device finishing
static void ext_on_finished(void *data, struct ext_data_control_device_v1 *dev) {
  (void)data; (void)dev;
  dc_on_finished();
}
static const struct ext_data_control_device_v1_listener ext_device_listener = {
  .data_offer = ext_on_data_offer,
  .selection = ext_on_selection,
  .finished = ext_on_finished,
  .primary_selection = ext_on_primary_selection,
};

// write the outgoing clipboard data to the requesting descriptor
static void dc_on_source_send(void *data, int32_t fd) {
  struct outgoing *node = data;
  if (getenv("RHIZO_WLBRIDGE_TEST_HOLD_SEND")) {
    if (node->held_fd >= 0) close(node->held_fd);
    node->held_fd = fd;
    return;
  }
  size_t off = 0;
  while (off < node->len) {
    ssize_t n = write(fd, node->data + off, node->len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    off += (size_t)n;
  }
  close(fd);
}
// remove and free the canceled selection source
static void dc_on_source_canceled(void *data, void *src) {
  struct outgoing *node = data;
  struct outgoing **cur = &outgoing_head;
  while (*cur && *cur != node) cur = &(*cur)->next;
  if (*cur == node) *cur = node->next;
  dc_source_destroy(src);
  free(node->mime);
  free(node->data);
  free(node);
}
// handle a send request on a wlr data control source
static void wlr_on_source_send(void *data, struct zwlr_data_control_source_v1 *src,
                               const char *mime_type, int32_t fd) {
  (void)src; (void)mime_type;
  dc_on_source_send(data, fd);
}
// handle the cancellation of a wlr data control source
static void wlr_on_source_canceled(void *data, struct zwlr_data_control_source_v1 *src) {
  dc_on_source_canceled(data, src);
}
static const struct zwlr_data_control_source_v1_listener wlr_source_listener = {
  .send = wlr_on_source_send, .cancelled = wlr_on_source_canceled,
};
// handle a send request on an ext data control source
static void ext_on_source_send(void *data, struct ext_data_control_source_v1 *src,
                               const char *mime_type, int32_t fd) {
  (void)src; (void)mime_type;
  dc_on_source_send(data, fd);
}
// handle the cancellation of an ext data control source
static void ext_on_source_canceled(void *data, struct ext_data_control_source_v1 *src) {
  dc_on_source_canceled(data, src);
}
static const struct ext_data_control_source_v1_listener ext_source_listener = {
  .send = ext_on_source_send, .cancelled = ext_on_source_canceled,
};

// add the listener of the data control kind to a source
static void dc_source_add_listener(void *src, struct outgoing *node) {
  if (dc_ext) ext_data_control_source_v1_add_listener(src, &ext_source_listener, node);
  else zwlr_data_control_source_v1_add_listener(src, &wlr_source_listener, node);
}
// get the data control device for the seat
static void dc_get_device(void) {
  if (dc_ext) {
    device = ext_data_control_manager_v1_get_data_device(manager, seat);
    ext_data_control_device_v1_add_listener(device, &ext_device_listener, NULL);
  } else {
    device = zwlr_data_control_manager_v1_get_data_device(manager, seat);
    zwlr_data_control_device_v1_add_listener(device, &wlr_device_listener, NULL);
  }
}

// acknowledge the layer surface configure
static void on_layer_surface_configure(void *data, struct zwlr_layer_surface_v1 *ls,
                                       uint32_t serial, uint32_t width, uint32_t height) {
  (void)data; (void)width; (void)height;
  zwlr_layer_surface_v1_ack_configure(ls, serial);
  pad_configured = 1;
}
// report that the compositor closed the drag pad
static void on_layer_surface_closed(void *data, struct zwlr_layer_surface_v1 *ls) {
  (void)data; (void)ls;
  printf("error drag pad closed by compositor\n");
  fflush(stdout);
}
static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
  .configure = on_layer_surface_configure, .closed = on_layer_surface_closed,
};

// acknowledge the xdg surface configure
static void on_pad_xdg_surface_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
  (void)data;
  xdg_surface_ack_configure(xs, serial);
  pad_configured = 1;
}
static const struct xdg_surface_listener pad_xdg_surface_listener = {
  .configure = on_pad_xdg_surface_configure,
};
// ignore the configure of the pad toplevel
static void on_pad_xdg_toplevel_configure(void *data, struct xdg_toplevel *tl, int32_t width,
                                          int32_t height, struct wl_array *states) {
  (void)data; (void)tl; (void)width; (void)height; (void)states;
}
// report that the compositor closed the pad toplevel
static void on_pad_xdg_toplevel_close(void *data, struct xdg_toplevel *tl) {
  (void)data; (void)tl;
  printf("error drag pad closed by compositor\n");
  fflush(stdout);
}
static const struct xdg_toplevel_listener pad_xdg_toplevel_listener = {
  .configure = on_pad_xdg_toplevel_configure, .close = on_pad_xdg_toplevel_close,
};

// destroy the drag pad
static void destroy_pad(void) {
  if (!pad) return;
  if (pad->buffer) wl_buffer_destroy(pad->buffer);
  if (pad->pool) wl_shm_pool_destroy(pad->pool);
  if (pad->layer_surface) zwlr_layer_surface_v1_destroy(pad->layer_surface);
  if (pad->xdg_toplevel) xdg_toplevel_destroy(pad->xdg_toplevel);
  if (pad->xdg_surface) xdg_surface_destroy(pad->xdg_surface);
  if (pad->surface) wl_surface_destroy(pad->surface);
  free(pad);
  pad = NULL;
  pad_configured = 0;
  pad_abs_known = 0;
  pointer_on_pad = 0;
  if (pad_has_keyboard) {
    printf("focus away\n");
    fflush(stdout);
  }
  pad_has_keyboard = 0;
  free_dnd_offer(pad_selection, 1);
  pad_selection = NULL;
}

// create a shared memory file of a size
static int create_shm_file(size_t size) {
  int fd = memfd_create("rhizo-dragpad", MFD_CLOEXEC);
  if (fd < 0) return -1;
  if (ftruncate(fd, (off_t)size) < 0) {
    close(fd);
    return -1;
  }
  return fd;
}

// fill the pad and set its input region
static int map_pad_buffer(struct pad *p) {
  int32_t stride = PAD_SIZE * 4;
  size_t size = (size_t)stride * PAD_SIZE;
  int fd = create_shm_file(size);
  if (fd < 0) {
    printf("error shm file for drag pad: %s\n", strerror(errno));
    fflush(stdout);
    return 0;
  }
  void *mem = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (mem == MAP_FAILED) {
    printf("error mmap for drag pad: %s\n", strerror(errno));
    fflush(stdout);
    close(fd);
    return 0;
  }
  uint32_t *px = mem;
  for (size_t i = 0; i < size / 4; i++) px[i] = 0xff404080;
  munmap(mem, size);

  p->pool = wl_shm_create_pool(shm, fd, (int32_t)size);
  close(fd);
  p->buffer = wl_shm_pool_create_buffer(p->pool, 0, PAD_SIZE, PAD_SIZE, stride, WL_SHM_FORMAT_ARGB8888);

  struct wl_region *region = wl_compositor_create_region(compositor);
  wl_region_add(region, 0, 0, PAD_SIZE, PAD_SIZE);
  wl_surface_set_input_region(p->surface, region);
  wl_region_destroy(region);

  wl_surface_attach(p->surface, p->buffer, 0, 0);
  wl_surface_damage_buffer(p->surface, 0, 0, PAD_SIZE, PAD_SIZE);
  wl_surface_commit(p->surface);
  return 1;
}

// create and map the drag pad
static int create_pad(void) {
  if (pad) return 1;
  const int use_xdg = pad_mode_xdg || !layer_shell;
  if (!compositor || !shm || (use_xdg ? !wm_base : !layer_shell)) {
    printf("error drag pad needs wl_compositor, wl_shm and %s\n",
           use_xdg ? "xdg_wm_base" : "zwlr_layer_shell_v1");
    fflush(stdout);
    return 0;
  }
  struct pad *p = calloc(1, sizeof(*p));
  p->surface = wl_compositor_create_surface(compositor);
  if (use_xdg) {
    p->xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, p->surface);
    xdg_surface_add_listener(p->xdg_surface, &pad_xdg_surface_listener, NULL);
    p->xdg_toplevel = xdg_surface_get_toplevel(p->xdg_surface);
    xdg_toplevel_add_listener(p->xdg_toplevel, &pad_xdg_toplevel_listener, NULL);
    xdg_toplevel_set_title(p->xdg_toplevel, "rhizo-dragpad");
    xdg_toplevel_set_app_id(p->xdg_toplevel, "rhizo-dragpad");
  } else {
    p->layer_surface = zwlr_layer_shell_v1_get_layer_surface(
        layer_shell, p->surface, output, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "rhizo-dragpad");
    zwlr_layer_surface_v1_set_size(p->layer_surface, PAD_SIZE, PAD_SIZE);
    zwlr_layer_surface_v1_set_anchor(p->layer_surface,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    zwlr_layer_surface_v1_add_listener(p->layer_surface, &layer_surface_listener, NULL);
    pad_abs_x = (uint32_t)(output_x > 0 ? output_x : 0);
    pad_abs_y = (uint32_t)(output_y > 0 ? output_y : 0);
    pad_abs_known = 1;
  }

  pad = p;
  pad_configured = 0;
  wl_surface_commit(p->surface);
  if (wl_display_roundtrip(display) < 0 || !pad_configured) {
    printf("error drag pad did not configure\n");
    fflush(stdout);
    destroy_pad();
    return 0;
  }
  if (!map_pad_buffer(p)) {
    destroy_pad();
    return 0;
  }
  return 1;
}

// record a pointer enter on the pad
static void on_pointer_enter(void *data, struct wl_pointer *p, uint32_t serial,
                             struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
  (void)data; (void)p; (void)serial;
  fprintf(stderr, "wlbridge: pointer enter surface=%u pad=%u at %d,%d\n",
          surface ? wl_proxy_get_id((struct wl_proxy *)surface) : 0,
          pad && pad->surface ? wl_proxy_get_id((struct wl_proxy *)pad->surface) : 0,
          wl_fixed_to_int(x), wl_fixed_to_int(y));
  if (!pad || surface != pad->surface) return;
  pointer_on_pad = 1;
  pad_enters++;
  if (vp_pointer) {
    int32_t sx = wl_fixed_to_int(x), sy = wl_fixed_to_int(y);
    pad_abs_x = (uint32_t)((int64_t)last_sent_abs_x - sx);
    pad_abs_y = (uint32_t)((int64_t)last_sent_abs_y - sy);
    pad_abs_known = 1;
  }
}
// clear the pointer-on-pad flag
static void on_pointer_leave(void *data, struct wl_pointer *p, uint32_t serial,
                             struct wl_surface *surface) {
  (void)data; (void)p; (void)serial;
  if (pad && surface == pad->surface) pointer_on_pad = 0;
}
static void start_drag_from_pad(struct dnd_payload *payload, uint32_t serial);
// ignore pointer motion
static void on_pointer_motion(void *data, struct wl_pointer *p, uint32_t time,
                              wl_fixed_t x, wl_fixed_t y) {
  (void)data; (void)p; (void)time; (void)x; (void)y;
}
// record the pointer button press serial
static void on_pointer_button(void *data, struct wl_pointer *p, uint32_t serial,
                              uint32_t time, uint32_t button, uint32_t state) {
  (void)data; (void)p; (void)time; (void)button;
  if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
    press_serial = serial;
    have_press_serial = 1;
    if (armed_drag && pointer_on_pad) {
      struct dnd_payload *payload = armed_drag;
      armed_drag = NULL;
      start_drag_from_pad(payload, serial);
    }
  }
}
// ignore pointer axis events
static void on_pointer_axis(void *data, struct wl_pointer *p, uint32_t time,
                            uint32_t axis, wl_fixed_t value) {
  (void)data; (void)p; (void)time; (void)axis; (void)value;
}
static void on_seat_capabilities(void *data, struct wl_seat *s, uint32_t caps);
static void on_seat_name(void *data, struct wl_seat *s, const char *name);

static const struct wl_pointer_listener pointer_listener = {
  .enter = on_pointer_enter, .leave = on_pointer_leave, .motion = on_pointer_motion,
  .button = on_pointer_button, .axis = on_pointer_axis,
};

// close the keymap descriptor without using it
static void on_keyboard_keymap(void *data, struct wl_keyboard *k, uint32_t format, int32_t fd,
                               uint32_t size) {
  (void)data; (void)k; (void)format; (void)size;
  close(fd);
}
// note that the pad has keyboard focus
static void on_keyboard_enter(void *data, struct wl_keyboard *k, uint32_t serial,
                              struct wl_surface *surface, struct wl_array *keys) {
  (void)data; (void)k; (void)keys;
  if (!pad || surface != pad->surface) return;
  pad_has_keyboard = 1;
  keyboard_serial = serial;
  printf("focus pad\n");
  fflush(stdout);
}
// clear the pad keyboard focus
static void on_keyboard_leave(void *data, struct wl_keyboard *k, uint32_t serial,
                              struct wl_surface *surface) {
  (void)data; (void)k; (void)serial;
  if (!pad || surface != pad->surface) return;
  pad_has_keyboard = 0;
  free_dnd_offer(pad_selection, 1);
  pad_selection = NULL;
  printf("focus away\n");
  fflush(stdout);
}
// record the key serial while the pad has keyboard focus
static void on_keyboard_key(void *data, struct wl_keyboard *k, uint32_t serial, uint32_t time,
                            uint32_t key, uint32_t state) {
  (void)data; (void)k; (void)time; (void)key; (void)state;
  if (pad_has_keyboard) keyboard_serial = serial;
}
// ignore keyboard modifier events
static void on_keyboard_modifiers(void *data, struct wl_keyboard *k, uint32_t serial,
                                  uint32_t depressed, uint32_t latched, uint32_t locked,
                                  uint32_t group) {
  (void)data; (void)k; (void)serial; (void)depressed; (void)latched; (void)locked; (void)group;
}
static const struct wl_keyboard_listener keyboard_listener = {
  .keymap = on_keyboard_keymap, .enter = on_keyboard_enter, .leave = on_keyboard_leave,
  .key = on_keyboard_key, .modifiers = on_keyboard_modifiers,
};

// bind or release the seat pointer and keyboard
static void on_seat_capabilities(void *data, struct wl_seat *s, uint32_t caps) {
  (void)data; (void)s;
  int has_pointer = (caps & WL_SEAT_CAPABILITY_POINTER) != 0;
  if (has_pointer && !pointer) {
    pointer = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(pointer, &pointer_listener, NULL);
  } else if (!has_pointer && pointer) {
    wl_pointer_release(pointer);
    pointer = NULL;
  }
  int has_keyboard = (caps & WL_SEAT_CAPABILITY_KEYBOARD) != 0;
  if (selection_via_pad && has_keyboard && !keyboard) {
    keyboard = wl_seat_get_keyboard(seat);
    wl_keyboard_add_listener(keyboard, &keyboard_listener, NULL);
  } else if (!has_keyboard && keyboard) {
    wl_keyboard_destroy(keyboard);
    keyboard = NULL;
    pad_has_keyboard = 0;
  }
}

// ignore the seat name
static void on_seat_name(void *data, struct wl_seat *s, const char *name) {
  (void)data; (void)s; (void)name;
}

static const struct wl_seat_listener seat_listener = {
  .capabilities = on_seat_capabilities,
  .name = on_seat_name,
};

// add a mime type to a drag offer
static void on_dnd_offer_mime(void *data, struct wl_data_offer *offer, const char *mime_type) {
  (void)offer;
  struct dnd_offer *pending = data;
  if (pending->n_mimes == pending->cap_mimes) {
    pending->cap_mimes = pending->cap_mimes ? pending->cap_mimes * 2 : 4;
    pending->mimes = realloc(pending->mimes, pending->cap_mimes * sizeof(char *));
  }
  pending->mimes[pending->n_mimes++] = strdup(mime_type);
}
// ignore the source actions of a drag offer
static void on_dnd_offer_source_actions(void *data, struct wl_data_offer *offer, uint32_t actions) {
  (void)data; (void)offer; (void)actions;
}
// ignore the action of a drag offer
static void on_dnd_offer_action(void *data, struct wl_data_offer *offer, uint32_t action) {
  (void)data; (void)offer; (void)action;
}
static const struct wl_data_offer_listener dnd_offer_listener = {
  .offer = on_dnd_offer_mime,
  .source_actions = on_dnd_offer_source_actions,
  .action = on_dnd_offer_action,
};

// start tracking a new drag offer
static void on_dnd_data_offer(void *data, struct wl_data_device *dev, struct wl_data_offer *id) {
  (void)data; (void)dev;
  struct dnd_offer *pending = calloc(1, sizeof(*pending));
  pending->offer = id;
  wl_data_offer_set_user_data(id, pending);
  wl_data_offer_add_listener(id, &dnd_offer_listener, pending);
}
// accept an incoming drag and list its mimes
static void on_dnd_enter(void *data, struct wl_data_device *dev, uint32_t serial,
                         struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y,
                         struct wl_data_offer *id) {
  (void)data; (void)dev; (void)surface; (void)x; (void)y;
  struct dnd_offer *next = id ? wl_data_offer_get_user_data(id) : NULL;
  if (current_dnd_offer && current_dnd_offer != next) free_dnd_offer(current_dnd_offer, 1);
  current_dnd_offer = next;
  if (!current_dnd_offer || dnd_source_active) return;
  static const char *const carried[] = {"text/plain;charset=utf-8", "text/plain", "image/png"};
  for (size_t c = 0; c < sizeof(carried) / sizeof(carried[0]); c++) {
    size_t i = 0;
    while (i < current_dnd_offer->n_mimes && strcmp(current_dnd_offer->mimes[i], carried[c])) i++;
    if (i == current_dnd_offer->n_mimes) continue;
    char *first = current_dnd_offer->mimes[0];
    current_dnd_offer->mimes[0] = current_dnd_offer->mimes[i];
    current_dnd_offer->mimes[i] = first;
    break;
  }
  wl_data_offer_set_actions(current_dnd_offer->offer, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY,
                            WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
  wl_data_offer_accept(current_dnd_offer->offer, serial,
                       current_dnd_offer->n_mimes ? current_dnd_offer->mimes[0] : NULL);
  printf("dragenter");
  for (size_t i = 0; i < current_dnd_offer->n_mimes; i++) printf(" %s", current_dnd_offer->mimes[i]);
  printf("\n");
  fflush(stdout);
}
// drop the current drag offer when the drag leaves
static void on_dnd_leave(void *data, struct wl_data_device *dev) {
  (void)data; (void)dev;
  free_dnd_offer(current_dnd_offer, 1);
  current_dnd_offer = NULL;
}
// ignore drag motion
static void on_dnd_motion(void *data, struct wl_data_device *dev, uint32_t time,
                          wl_fixed_t x, wl_fixed_t y) {
  (void)data; (void)dev; (void)time; (void)x; (void)y;
}
static struct dnd_offer *drop_offer;

// take the current drag offer when it is dropped
static void on_dnd_drop(void *data, struct wl_data_device *dev) {
  (void)data; (void)dev;
  if (!current_dnd_offer || dnd_source_active || current_dnd_offer->n_mimes == 0) {
    free_dnd_offer(current_dnd_offer, 1);
    current_dnd_offer = NULL;
    return;
  }
  drop_offer = current_dnd_offer;
  current_dnd_offer = NULL;
}
// print the pad selection mime types
static void on_dnd_selection(void *data, struct wl_data_device *dev, struct wl_data_offer *id) {
  (void)data; (void)dev;
  if (!selection_via_pad) {
    if (id) free_dnd_offer(wl_data_offer_get_user_data(id), 1);
    return;
  }
  selection_gen++;
  free_dnd_offer(pad_selection, 1);
  pad_selection = id ? wl_data_offer_get_user_data(id) : NULL;
  if (!pad_selection) {
    printf("selection none\n");
  } else {
    printf("selection");
    for (size_t i = 0; i < pad_selection->n_mimes; i++) printf(" %s", pad_selection->mimes[i]);
    printf("\n");
  }
  fflush(stdout);
}

// ignore the target of the pad source
static void on_pad_source_target(void *data, struct wl_data_source *src, const char *mime_type) {
  (void)data; (void)src; (void)mime_type;
}
// write the pad source data to the requesting descriptor
static void on_pad_source_send(void *data, struct wl_data_source *src, const char *mime_type,
                               int32_t fd) {
  (void)src; (void)mime_type;
  struct pad_outgoing *node = data;
  size_t off = 0;
  while (off < node->len) {
    ssize_t n = write(fd, node->data + off, node->len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    off += (size_t)n;
  }
  close(fd);
}
// remove and free the canceled pad selection
static void on_pad_source_canceled(void *data, struct wl_data_source *src) {
  struct pad_outgoing *node = data;
  struct pad_outgoing **cur = &pad_outgoing_head;
  while (*cur && *cur != node) cur = &(*cur)->next;
  if (*cur == node) *cur = node->next;
  wl_data_source_destroy(src);
  free(node->data);
  free(node);
  printf("canceled selection\n");
  fflush(stdout);
}
// ignore a pad source event
static void on_pad_source_noop(void *data, struct wl_data_source *src) {
  (void)data; (void)src;
}
// ignore the action of the pad source
static void on_pad_source_action(void *data, struct wl_data_source *src, uint32_t action) {
  (void)data; (void)src; (void)action;
}
static const struct wl_data_source_listener pad_source_listener = {
  .target = on_pad_source_target, .send = on_pad_source_send,
  .cancelled = on_pad_source_canceled, .dnd_drop_performed = on_pad_source_noop,
  .dnd_finished = on_pad_source_noop, .action = on_pad_source_action,
};
static const struct wl_data_device_listener dnd_device_listener = {
  .data_offer = on_dnd_data_offer,
  .enter = on_dnd_enter,
  .leave = on_dnd_leave,
  .motion = on_dnd_motion,
  .drop = on_dnd_drop,
  .selection = on_dnd_selection,
};

// read and print the queued drop
static void process_pending_drop(void) {
  struct dnd_offer *o = drop_offer;
  drop_offer = NULL;
  if (!o) return;
  const char *mime = o->mimes[0];

  int pfd[2];
  if (pipe(pfd) != 0) {
    printf("error pipe failed: %s\n", strerror(errno));
    fflush(stdout);
    free_dnd_offer(o, 1);
    return;
  }
  wl_data_offer_receive(o->offer, mime, pfd[1]);
  close(pfd[1]);
  wl_display_roundtrip(display);

  size_t cap = 65536, len = 0;
  unsigned char *buf = malloc(cap);
  if (!buf) {
    printf("error out of memory receiving %s\n", mime);
    fflush(stdout);
    close(pfd[0]);
    free_dnd_offer(o, 1);
    return;
  }
  int overflow = 0, fatal = 0, oom = 0, timed_out = 0;
  uint32_t deadline = now_ms() + 60000;
  for (;;) {
    short revents = 0;
    int32_t remaining = (int32_t)(deadline - now_ms());
    if (remaining <= 0) { timed_out = 1; break; }
    if (wl_pump(pfd[0], POLLIN, &revents, remaining) < 0) { fatal = 1; break; }
    if (!(revents & (POLLIN | POLLHUP))) continue;
    unsigned char tmp[65536];
    ssize_t n = read(pfd[0], tmp, sizeof(tmp));
    if (n < 0) {
      if (errno == EINTR) continue;
      printf("error read failed for %s: %s\n", mime, strerror(errno));
      fflush(stdout);
      free(buf);
      close(pfd[0]);
      free_dnd_offer(o, 1);
      return;
    }
    if (n == 0) break;
    if (overflow || oom) continue;
    if (len + (size_t)n > MAX_PAYLOAD) { overflow = 1; continue; }
    if (len + (size_t)n > cap) {
      unsigned char *grown = grow_buf(buf, &cap, len + (size_t)n);
      if (!grown) { oom = 1; buf = NULL; continue; }
      buf = grown;
    }
    memcpy(buf + len, tmp, (size_t)n);
    len += (size_t)n;
  }
  close(pfd[0]);
  if (fatal) {
    free(buf);
    free_dnd_offer(o, 1);
    emit_conn_error();
    should_quit = 1;
    return;
  }
  if (timed_out) {
    printf("error drag source never finished sending %s within 60s\n", mime);
    fflush(stdout);
    free(buf);
    free_dnd_offer(o, 1);
    return;
  }
  if (oom) {
    printf("error out of memory receiving %s\n", mime);
    fflush(stdout);
    free_dnd_offer(o, 1);
    return;
  }
  if (overflow) {
    printf("error payload for %s exceeds %zu bytes\n", mime, MAX_PAYLOAD);
    fflush(stdout);
    free(buf);
    free_dnd_offer(o, 1);
    return;
  }
  char *b64 = b64_encode(buf, len);
  free(buf);
  if (!b64) {
    printf("error out of memory encoding %s\n", mime);
    fflush(stdout);
    free_dnd_offer(o, 1);
    return;
  }
  printf("dropped %s %s\n", mime, b64);
  fflush(stdout);
  free(b64);
  wl_data_offer_finish(o->offer);
  free_dnd_offer(o, 1);
}

// free the finished dragto payload
static void finish_dragto(void) {
  dnd_source_active = 0;
  if (dnd_payload) {
    free(dnd_payload->mime);
    free(dnd_payload->data);
    free(dnd_payload);
    dnd_payload = NULL;
  }
  if (!dragpad_persistent) destroy_pad();
}
// print the drag target mime type
static void on_dnd_source_target(void *data, struct wl_data_source *src, const char *mime_type) {
  (void)data; (void)src;
  printf("dragtarget %s\n", mime_type ? mime_type : "(none)");
  fflush(stdout);
}
// write the drag payload to the requesting descriptor
static void on_dnd_source_send(void *data, struct wl_data_source *src, const char *mime_type, int32_t fd) {
  (void)src; (void)mime_type;
  struct dnd_payload *p = data;
  size_t off = 0;
  while (off < p->len) {
    ssize_t n = write(fd, p->data + off, p->len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    off += (size_t)n;
  }
  close(fd);
}
// report that the drag was canceled and destroy the source
static void on_dnd_source_canceled(void *data, struct wl_data_source *src) {
  (void)data;
  printf("dragto canceled\n");
  fflush(stdout);
  wl_data_source_destroy(src);
  finish_dragto();
}
// ignore the drop-performed event of the drag source
static void on_dnd_source_dnd_drop_performed(void *data, struct wl_data_source *src) {
  (void)data; (void)src;
}
// report that the drag finished and destroy the source
static void on_dnd_source_dnd_finished(void *data, struct wl_data_source *src) {
  (void)data;
  printf("dragto done\n");
  fflush(stdout);
  wl_data_source_destroy(src);
  finish_dragto();
}
// report the action chosen for the drag
static void on_dnd_source_action(void *data, struct wl_data_source *src, uint32_t dnd_action) {
  (void)data; (void)src;
  printf("dragaction %u\n", dnd_action);
  fflush(stdout);
}
static const struct wl_data_source_listener dnd_source_listener = {
  .target = on_dnd_source_target,
  .send = on_dnd_source_send,
  .cancelled = on_dnd_source_canceled,
  .dnd_drop_performed = on_dnd_source_dnd_drop_performed,
  .dnd_finished = on_dnd_source_dnd_finished,
  .action = on_dnd_source_action,
};

// start a drag from the pad
static void start_drag_from_pad(struct dnd_payload *payload, uint32_t serial) {
  struct wl_data_source *source = wl_data_device_manager_create_data_source(data_manager);
  wl_data_source_add_listener(source, &dnd_source_listener, payload);
  wl_data_source_offer(source, payload->mime);
  wl_data_source_set_actions(source, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
  wl_data_device_start_drag(dnd_device, source, pad->surface, NULL, serial);
  wl_display_flush(display);
  dnd_source_active = 1;
  dnd_payload = payload;
  printf("dragstarted %s\n", payload->mime);
  fflush(stdout);
}

// poll the Wayland display and an extra fd
static int wl_pump(int extra_fd, short extra_events, short *extra_revents, int timeout_ms) {
  while (wl_display_prepare_read(display) != 0)
    if (wl_display_dispatch_pending(display) < 0) return -1;
  short wlevents = POLLIN;
  if (wl_display_flush(display) < 0) {
    if (errno == EAGAIN) wlevents |= POLLOUT;
    else { wl_display_cancel_read(display); return -1; }
  }
  struct pollfd fds[2] = {
    { .fd = wl_display_get_fd(display), .events = wlevents },
    { .fd = extra_fd, .events = extra_events },
  };
  int nfds = extra_fd >= 0 ? 2 : 1;
  struct timespec ts = { .tv_sec = timeout_ms / 1000, .tv_nsec = (long)(timeout_ms % 1000) * 1000000L };
  if (ppoll(fds, nfds, timeout_ms < 0 ? NULL : &ts, &pump_sigmask) < 0) {
    wl_display_cancel_read(display);
    if (errno == EINTR) { if (extra_revents) *extra_revents = 0; return 0; }
    return -1;
  }
  if (fds[0].revents & POLLIN) {
    if (wl_display_read_events(display) < 0) return -1;
  } else {
    wl_display_cancel_read(display);
  }
  if (wl_display_dispatch_pending(display) < 0) return -1;
  if (extra_revents) *extra_revents = nfds == 2 ? fds[1].revents : 0;
  return 0;
}

// report that the Wayland connection was lost
static void emit_conn_error(void) {
  printf("error wayland connection lost\n");
  fflush(stdout);
}

// grow a byte buffer to the needed size
static unsigned char *grow_buf(unsigned char *buf, size_t *cap, size_t need) {
  size_t newcap = *cap ? *cap : 65536;
  while (newcap < need) newcap *= 2;
  unsigned char *grown = realloc(buf, newcap);
  if (!grown) {
    free(buf);
    return NULL;
  }
  *cap = newcap;
  return grown;
}

// print the mime types of the current selection
static void cmd_offers(void) {
  printf("offers");
  if (selection_via_pad) {
    if (pad_selection)
      for (size_t i = 0; i < pad_selection->n_mimes; i++) printf(" %s", pad_selection->mimes[i]);
  } else if (current_selection) {
    for (size_t i = 0; i < current_selection->n_mimes; i++) printf(" %s", current_selection->mimes[i]);
  }
  printf("\n");
  fflush(stdout);
}

// set the selection through the pad
static void cmd_set_via_pad(const char *mime, const unsigned char *data, size_t len) {
  if (!data_manager || !dnd_device) {
    printf("error no data device\n");
    fflush(stdout);
    return;
  }
  if (!pad || !pad_has_keyboard) {
    printf("error the pad does not hold keyboard focus, so the compositor would refuse the selection\n");
    fflush(stdout);
    return;
  }
  struct pad_outgoing *node = calloc(1, sizeof(*node));
  char *mimes_copy = node ? strdup(mime) : NULL;
  unsigned char *copy = node ? malloc(len ? len : 1) : NULL;
  if (!node || !mimes_copy || !copy) {
    printf("error out of memory setting the selection for %s\n", mime);
    fflush(stdout);
    free(node);
    free(mimes_copy);
    free(copy);
    return;
  }
  memcpy(copy, data, len);
  node->data = copy;
  node->len = len;
  node->src = wl_data_device_manager_create_data_source(data_manager);
  wl_data_source_add_listener(node->src, &pad_source_listener, node);
  char *save = NULL;
  for (char *m = strtok_r(mimes_copy, ",", &save); m; m = strtok_r(NULL, ",", &save))
    wl_data_source_offer(node->src, m);
  free(mimes_copy);
  wl_data_device_set_selection(dnd_device, node->src, keyboard_serial);
  node->next = pad_outgoing_head;
  pad_outgoing_head = node;
  wl_display_roundtrip(display);
}

// return whether a drag offer lists a mime type
static int dnd_mime_in_list(const struct dnd_offer *s, const char *mime) {
  if (!s) return 0;
  for (size_t i = 0; i < s->n_mimes; i++)
    if (!strcmp(s->mimes[i], mime)) return 1;
  return 0;
}

// print an error line for a get
static void get_answer_error(const char *tag, const char *fmt, ...) {
  va_list ap;
  printf("error ");
  if (tag) printf("get %s ", tag);
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  printf("\n");
  fflush(stdout);
}
// print a nodata answer for a mime type and tag
static void get_answer_nodata(const char *mime, const char *tag) {
  printf("nodata %s%s%s\n", mime, tag ? " " : "", tag ? tag : "");
  fflush(stdout);
}

// print the selection data
static void cmd_get(const char *mime, const char *tag) {
  if (selection_via_pad && !pad_has_keyboard) {
    get_answer_error(tag, "the pad does not hold keyboard focus, so the compositor offers it no selection");
    return;
  }
  if (selection_via_pad ? !dnd_mime_in_list(pad_selection, mime)
                        : !mime_in_list(current_selection, mime)) {
    get_answer_nodata(mime, tag);
    return;
  }
  if (!selection_via_pad && mime_in_list(current_selection, PASSWORD_HINT_MIME)) {
    get_answer_nodata(mime, tag);
    return;
  }
  int pfd[2];
  if (pipe(pfd) != 0) {
    get_answer_error(tag, "pipe failed: %s", strerror(errno));
    return;
  }
  const unsigned long read_gen = selection_gen;
  if (selection_via_pad)
    wl_data_offer_receive(pad_selection->offer, mime, pfd[1]);
  else
    dc_offer_receive(current_selection->offer, mime, pfd[1]);
  close(pfd[1]);
  int rt = wl_display_roundtrip(display);
  if (getenv("RHIZO_WLBRIDGE_DEBUG"))
    fprintf(stderr, "wlbridge: receive mime=%s roundtrip=%d display_err=%d\n",
            mime, rt, wl_display_get_error(display));

  size_t cap = 65536, len = 0;
  unsigned char *buf = malloc(cap);
  if (!buf) {
    get_answer_error(tag, "out of memory reading %s", mime);
    close(pfd[0]);
    return;
  }
  int overflow = 0, fatal = 0, oom = 0, timed_out = 0, superseded = 0;
  uint32_t deadline = now_ms() + 60000;
  for (;;) {
    if (selection_gen != read_gen) { superseded = 1; break; }
    short revents = 0;
    int32_t remaining = (int32_t)(deadline - now_ms());
    if (remaining <= 0) { timed_out = 1; break; }
    if (wl_pump(pfd[0], POLLIN, &revents, remaining) < 0) { fatal = 1; break; }
    if (!(revents & (POLLIN | POLLHUP))) continue;
    unsigned char tmp[65536];
    ssize_t n = read(pfd[0], tmp, sizeof(tmp));
    if (n < 0) {
      if (errno == EINTR) continue;
      get_answer_error(tag, "read failed for %s: %s", mime, strerror(errno));
      free(buf);
      close(pfd[0]);
      return;
    }
    if (n == 0) break;
    if (overflow || oom) continue;
    if (len + (size_t)n > MAX_PAYLOAD) { overflow = 1; continue; }
    if (len + (size_t)n > cap) {
      unsigned char *grown = grow_buf(buf, &cap, len + (size_t)n);
      if (!grown) { oom = 1; buf = NULL; continue; }
      buf = grown;
    }
    memcpy(buf + len, tmp, (size_t)n);
    len += (size_t)n;
  }
  if (selection_gen != read_gen) superseded = 1;
  close(pfd[0]);
  if (fatal) { free(buf); emit_conn_error(); should_quit = 1; return; }
  if (superseded) {
    free(buf);
    get_answer_nodata(mime, tag);
    return;
  }
  if (timed_out) {
    get_answer_error(tag, "selection owner never finished sending %s within 60s", mime);
    free(buf);
    return;
  }
  if (oom) {
    get_answer_error(tag, "out of memory reading %s", mime);
    return;
  }
  if (overflow) {
    get_answer_error(tag, "payload for %s exceeds %zu bytes", mime, (size_t)MAX_PAYLOAD);
    free(buf);
    return;
  }
  char *b64 = b64_encode(buf, len);
  free(buf);
  if (!b64) {
    get_answer_error(tag, "out of memory encoding %s", mime);
    return;
  }
  printf("data %s %s%s%s\n", mime, b64, tag ? " " : "", tag ? tag : "");
  fflush(stdout);
  free(b64);
}

// set the selection from base64 data
static void cmd_set(const char *mime, const char *b64) {
  if (!selection_via_pad && (!manager || !device)) {
    printf("error no data control device\n");
    fflush(stdout);
    return;
  }
  size_t declen;
  unsigned char *data = b64_decode(b64, strlen(b64), &declen);
  if (!data) {
    printf("error invalid base64 for %s\n", mime);
    fflush(stdout);
    return;
  }
  if (declen > MAX_PAYLOAD) {
    printf("error payload for %s exceeds %zu bytes\n", mime, MAX_PAYLOAD);
    fflush(stdout);
    free(data);
    return;
  }
  if (selection_via_pad) {
    cmd_set_via_pad(mime, data, declen);
    free(data);
    return;
  }
  struct outgoing *node = calloc(1, sizeof(*node));
  char *mime_copy = node ? strdup(mime) : NULL;
  if (!node || !mime_copy) {
    printf("error out of memory setting the selection for %s\n", mime);
    fflush(stdout);
    free(node);
    free(mime_copy);
    free(data);
    return;
  }
  node->mime = mime_copy;
  node->data = data;
  node->len = declen;
  node->held_fd = -1;
  node->src = dc_create_source();
  dc_source_add_listener(node->src, node);
  {
    char *mimes_copy = strdup(mime);
    if (mimes_copy) {
      char *save = NULL;
      for (char *m = strtok_r(mimes_copy, ",", &save); m; m = strtok_r(NULL, ",", &save))
        dc_source_offer(node->src, m);
      free(mimes_copy);
    } else {
      dc_source_offer(node->src, mime);
    }
  }
  dc_set_selection(node->src);
  node->next = outgoing_head;
  outgoing_head = node;
}

// free a drag payload
static void free_payload(struct dnd_payload *p) {
  if (!p) return;
  free(p->mime);
  free(p->data);
  free(p);
}

// turn the drag pad on or off
static void cmd_dragpad(const char *arg) {
  if (!strcmp(arg, "on")) {
    if (!create_pad()) return;
    dragpad_persistent = 1;
    printf("padmapped\n");
    fflush(stdout);
    return;
  }
  if (!strcmp(arg, "off")) {
    dragpad_persistent = 0;
    free_payload(armed_drag);
    armed_drag = NULL;
    if (!dnd_source_active) destroy_pad();
    return;
  }
  printf("error dragpad needs on or off\n");
  fflush(stdout);
}

// arm a drag of the base64 payload
static void cmd_dragarm(const char *mime, const char *b64) {
  if (dnd_source_active || armed_drag) {
    printf("error drag already in progress\n");
    fflush(stdout);
    return;
  }
  if (!data_manager || !dnd_device) {
    printf("error drag and drop not available\n");
    fflush(stdout);
    return;
  }
  size_t declen;
  unsigned char *data = b64_decode(b64, strlen(b64), &declen);
  if (!data) {
    printf("error invalid base64 for %s\n", mime);
    fflush(stdout);
    return;
  }
  if (declen > MAX_PAYLOAD) {
    printf("error payload for %s exceeds %zu bytes\n", mime, MAX_PAYLOAD);
    fflush(stdout);
    free(data);
    return;
  }
  if (!create_pad()) {
    free(data);
    return;
  }
  struct dnd_payload *payload = calloc(1, sizeof(*payload));
  char *mime_copy = payload ? strdup(mime) : NULL;
  if (!payload || !mime_copy) {
    printf("error out of memory arming the drag for %s\n", mime);
    fflush(stdout);
    free(payload);
    free(mime_copy);
    free(data);
    return;
  }
  payload->mime = mime_copy;
  payload->data = data;
  payload->len = declen;
  armed_drag = payload;
  printf("dragarmed %s\n", mime);
  fflush(stdout);
}

// wait for the seat pointer
static int ensure_pointer(int timeout_ms) {
  int waited = 0;
  while (!pointer && waited < timeout_ms) {
    if (wl_display_roundtrip(display) < 0) return 0;
    if (pointer) break;
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 50 * 1000 * 1000 };
    nanosleep(&ts, NULL);
    waited += 50;
  }
  return pointer != NULL;
}

// press the left button at x and y
static void cmd_press(const char *xs, const char *ys) {
  if (!ensure_pointer(2000) || !vp_pointer || !output_have_mode) {
    printf("error pointer not available\n");
    fflush(stdout);
    return;
  }
  char *end;
  long x = strtol(xs, &end, 10);
  if (*end || x < 0) { printf("error invalid x: %s\n", xs); fflush(stdout); return; }
  long y = strtol(ys, &end, 10);
  if (*end || y < 0) { printf("error invalid y: %s\n", ys); fflush(stdout); return; }
  char why[160];
  if (!vp_reachable(x, y, why, sizeof(why))) { printf("error press %s\n", why); fflush(stdout); return; }
  vp_move_absolute((uint32_t)x, (uint32_t)y);
  zwlr_virtual_pointer_v1_frame(vp_pointer);
  zwlr_virtual_pointer_v1_button(vp_pointer, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
  zwlr_virtual_pointer_v1_frame(vp_pointer);
  wl_display_roundtrip(display);
  printf("pressed %ld %ld\n", x, y);
  fflush(stdout);
}

// move the pointer to x and y
static void cmd_moveto(const char *xs, const char *ys) {
  if (!vp_pointer || !output_have_mode) {
    printf("error pointer not available\n");
    fflush(stdout);
    return;
  }
  char *end;
  long x = strtol(xs, &end, 10);
  if (*end || x < 0) { printf("error invalid x: %s\n", xs); fflush(stdout); return; }
  long y = strtol(ys, &end, 10);
  if (*end || y < 0) { printf("error invalid y: %s\n", ys); fflush(stdout); return; }
  char why[160];
  if (!vp_reachable(x, y, why, sizeof(why))) { printf("error moveto %s\n", why); fflush(stdout); return; }
  const int steps = 4;
  for (int i = 1; i <= steps; i++) {
    vp_move_absolute((uint32_t)x, (uint32_t)y);
    zwlr_virtual_pointer_v1_frame(vp_pointer);
    if (wl_display_roundtrip(display) < 0) { emit_conn_error(); should_quit = 1; return; }
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 40L * 1000 * 1000 };
    nanosleep(&ts, NULL);
  }
  printf("movedto %ld %ld\n", x, y);
  fflush(stdout);
}

// release the left pointer button
static void cmd_release(void) {
  if (!vp_pointer) { printf("error pointer not available\n"); fflush(stdout); return; }
  zwlr_virtual_pointer_v1_button(vp_pointer, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
  zwlr_virtual_pointer_v1_frame(vp_pointer);
  wl_display_roundtrip(display);
  printf("released\n");
  fflush(stdout);
}

// find the pad origin on screen
static int discover_pad_position(void) {
  if (pad_abs_known) return 1;
  if (!pad || !vp_pointer || !output_have_mode) return 0;
  const uint32_t corners[][2] = {
    {(uint32_t)(output_x > 0 ? output_x : 0) + PAD_SIZE / 2,
     (uint32_t)(output_y > 0 ? output_y : 0) + PAD_SIZE / 2},
    {PAD_SIZE / 2, PAD_SIZE / 2},
  };
  for (size_t i = 0; i < sizeof(corners) / sizeof(corners[0]) && !pad_abs_known; i++) {
    if (!vp_reachable(corners[i][0], corners[i][1], NULL, 0)) continue;
    vp_move_absolute(corners[i][0], corners[i][1]);
    zwlr_virtual_pointer_v1_frame(vp_pointer);
    if (wl_display_roundtrip(display) < 0) return 0;
  }
  const long ccx = (long)output_x + output_width / 2, ccy = (long)output_y + output_height / 2;
  const long offsets[] = {0, -PAD_SIZE, PAD_SIZE, -PAD_SIZE * 2, PAD_SIZE * 2};
  const size_t n = sizeof(offsets) / sizeof(offsets[0]);
  for (size_t oy = 0; oy < n && !pad_abs_known; oy++) {
    for (size_t ox = 0; ox < n && !pad_abs_known; ox++) {
      long tx = ccx + offsets[ox], ty = ccy + offsets[oy];
      if (tx < 0 || ty < 0 || !vp_reachable(tx, ty, NULL, 0)) continue;
      vp_move_absolute((uint32_t)tx, (uint32_t)ty);
      zwlr_virtual_pointer_v1_frame(vp_pointer);
      if (wl_display_roundtrip(display) < 0) return 0;
    }
  }
  return pad_abs_known;
}

// print the pad origin
static void cmd_padorigin(void) {
  if (!pad) { printf("error the drag pad is not mapped\n"); fflush(stdout); return; }
  if (!ensure_pointer(2000) || !vp_pointer || !output_have_mode) {
    printf("error pointer not available\n");
    fflush(stdout);
    return;
  }
  if (!pointer_on_pad) {
    if (vp_reachable((long)pad_abs_x + PAD_SIZE / 2, (long)pad_abs_y + PAD_SIZE / 2, NULL, 0)) {
      vp_move_absolute(pad_abs_x + PAD_SIZE / 2, pad_abs_y + PAD_SIZE / 2);
      zwlr_virtual_pointer_v1_frame(vp_pointer);
      if (wl_display_roundtrip(display) < 0) { emit_conn_error(); should_quit = 1; return; }
    }
    if (!pointer_on_pad) {
      uint32_t assumed_x = pad_abs_x, assumed_y = pad_abs_y;
      pad_abs_known = 0;
      if (!discover_pad_position() || !pointer_on_pad) {
        printf("error the pointer never entered the drag pad: not at its assumed origin %u,%u "
               "(output %dx%d at %d,%d) nor anywhere discovery looked; %u enter(s) on it so far\n",
               assumed_x, assumed_y, (int)output_width, (int)output_height, (int)output_x,
               (int)output_y, pad_enters);
        fflush(stdout);
        return;
      }
    }
  }
  printf("padorigin %u %u\n", pad_abs_x, pad_abs_y);
  fflush(stdout);
}

// drag a payload from the pad
static void cmd_dragto(const char *xs, const char *ys, const char *mime, const char *b64) {
  if (dnd_source_active || armed_drag) {
    printf("error drag already in progress\n");
    fflush(stdout);
    return;
  }
  if (!ensure_pointer(2000)) {
    printf("error the seat has no pointer, so no press serial can exist\n");
    fflush(stdout);
    return;
  }
  if (!vp_pointer || !data_manager || !dnd_device || !output_have_mode) {
    printf("error drag and drop not available\n");
    fflush(stdout);
    return;
  }
  char *end;
  errno = 0;
  long x = strtol(xs, &end, 10);
  if (errno || *end || x < 0) {
    printf("error invalid x: %s\n", xs);
    fflush(stdout);
    return;
  }
  errno = 0;
  long y = strtol(ys, &end, 10);
  if (errno || *end || y < 0) {
    printf("error invalid y: %s\n", ys);
    fflush(stdout);
    return;
  }
  char why[160];
  if (!vp_reachable(x, y, why, sizeof(why))) {
    printf("error dragto %s\n", why);
    fflush(stdout);
    return;
  }

  size_t declen;
  unsigned char *data = b64_decode(b64, strlen(b64), &declen);
  if (!data) {
    printf("error invalid base64 for %s\n", mime);
    fflush(stdout);
    return;
  }
  if (declen > MAX_PAYLOAD) {
    printf("error payload for %s exceeds %zu bytes\n", mime, MAX_PAYLOAD);
    fflush(stdout);
    free(data);
    return;
  }

  if (!create_pad()) {
    free(data);
    return;
  }
  if (!discover_pad_position()) {
    printf("error could not locate the drag pad on screen\n");
    fflush(stdout);
    free(data);
    if (!dragpad_persistent) destroy_pad();
    return;
  }

  uint32_t cx = pad_abs_x + PAD_SIZE / 2, cy = pad_abs_y + PAD_SIZE / 2;
  vp_move_absolute(cx, cy);
  zwlr_virtual_pointer_v1_frame(vp_pointer);
  if (wl_display_roundtrip(display) < 0) {
    emit_conn_error();
    should_quit = 1;
    free(data);
    if (!dragpad_persistent) destroy_pad();
    return;
  }
  if (!pointer_on_pad) {
    uint32_t assumed_x = pad_abs_x, assumed_y = pad_abs_y;
    pad_abs_known = 0;
    if (!discover_pad_position() || !pointer_on_pad) {
      printf("error the pointer never entered the drag pad: not at its assumed origin %u,%u "
             "(output %dx%d at %d,%d) nor anywhere discovery looked; %u enter(s) on it so far\n",
             assumed_x, assumed_y, (int)output_width, (int)output_height, (int)output_x,
             (int)output_y, pad_enters);
      fflush(stdout);
      free(data);
      if (!dragpad_persistent) destroy_pad();
      return;
    }
    cx = pad_abs_x + PAD_SIZE / 2;
    cy = pad_abs_y + PAD_SIZE / 2;
    vp_move_absolute(cx, cy);
    zwlr_virtual_pointer_v1_frame(vp_pointer);
    if (wl_display_roundtrip(display) < 0) {
      emit_conn_error();
      should_quit = 1;
      free(data);
      if (!dragpad_persistent) destroy_pad();
      return;
    }
  }
  zwlr_virtual_pointer_v1_button(vp_pointer, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
  zwlr_virtual_pointer_v1_frame(vp_pointer);
  have_press_serial = 0;
  if (wl_display_roundtrip(display) < 0) {
    emit_conn_error();
    should_quit = 1;
    free(data);
    if (!dragpad_persistent) destroy_pad();
    return;
  }
  if (!have_press_serial) {
    printf("error no press serial from compositor, with the pointer %s the pad at %u,%u\n",
           pointer_on_pad ? "on" : "off", pad_abs_x, pad_abs_y);
    fflush(stdout);
    free(data);
    if (!dragpad_persistent) destroy_pad();
    return;
  }

  struct dnd_payload *payload = calloc(1, sizeof(*payload));
  char *drag_mime_copy = payload ? strdup(mime) : NULL;
  if (!payload || !drag_mime_copy) {
    printf("error out of memory starting the drag for %s\n", mime);
    fflush(stdout);
    free(payload);
    free(drag_mime_copy);
    free(data);
    if (!dragpad_persistent) destroy_pad();
    return;
  }
  payload->mime = drag_mime_copy;
  payload->data = data;
  payload->len = declen;
  start_drag_from_pad(payload, press_serial);

  const int steps = 6;
  const int step_ms = 40;
  for (int i = 1; i <= steps; i++) {
    uint32_t ix = (uint32_t)(cx + (x - (long)cx) * i / steps);
    uint32_t iy = (uint32_t)(cy + (y - (long)cy) * i / steps);
    vp_move_absolute(ix, iy);
    zwlr_virtual_pointer_v1_frame(vp_pointer);
    if (wl_display_roundtrip(display) < 0) { emit_conn_error(); should_quit = 1; return; }
    struct timespec ts = { .tv_sec = 0, .tv_nsec = step_ms * 1000L * 1000L };
    nanosleep(&ts, NULL);
  }
  struct timespec dwell = { .tv_sec = 0, .tv_nsec = 250L * 1000 * 1000 };
  nanosleep(&dwell, NULL);
  if (wl_display_roundtrip(display) < 0) { emit_conn_error(); should_quit = 1; return; }
  zwlr_virtual_pointer_v1_button(vp_pointer, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
  zwlr_virtual_pointer_v1_frame(vp_pointer);
  wl_display_flush(display);
}

// return the next space-separated token
static char *next_token(char **cursor) {
  char *p = *cursor;
  while (*p == ' ') p++;
  if (*p == '\0') { *cursor = p; return NULL; }
  char *start = p;
  while (*p != '\0' && *p != ' ') p++;
  if (*p == ' ') { *p = '\0'; p++; }
  *cursor = p;
  return start;
}

// run a command line
static void handle_line(char *line) {
  char *cursor = line;
  char *cmd = next_token(&cursor);
  if (!cmd) return;
  if (!strcmp(cmd, "quit")) { should_quit = 1; return; }
  if (!strcmp(cmd, "offers")) { cmd_offers(); return; }
  if (!strcmp(cmd, "press")) {
    char *xs = next_token(&cursor), *ys = next_token(&cursor);
    if (!xs || !ys) { printf("error press needs x and y\n"); fflush(stdout); return; }
    cmd_press(xs, ys);
    return;
  }
  if (!strcmp(cmd, "release")) { cmd_release(); return; }
  if (!strcmp(cmd, "padorigin")) { cmd_padorigin(); return; }
  if (!strcmp(cmd, "moveto")) {
    char *xs = next_token(&cursor), *ys = next_token(&cursor);
    if (!xs || !ys) { printf("error moveto needs x and y\n"); fflush(stdout); return; }
    cmd_moveto(xs, ys);
    return;
  }
  if (!strcmp(cmd, "get")) {
    char *mime = next_token(&cursor);
    if (!mime) { printf("error get needs a mime type\n"); fflush(stdout); return; }
    char *tag = next_token(&cursor);
    if (tag) {
      size_t n = strlen(tag);
      int valid = n > 0 && n <= 32;
      for (size_t i = 0; valid && i < n; i++) valid = isalnum((unsigned char)tag[i]);
      if (!valid) { printf("error get tag must be 1-32 letters or digits\n"); fflush(stdout); return; }
    }
    cmd_get(mime, tag);
    return;
  }
  if (!strcmp(cmd, "set")) {
    char *mime = next_token(&cursor);
    if (!mime) { printf("error set needs a mime type\n"); fflush(stdout); return; }
    while (*cursor == ' ') cursor++;
    cmd_set(mime, cursor);
    return;
  }
  if (!strcmp(cmd, "dragpad")) {
    char *arg = next_token(&cursor);
    if (!arg) { printf("error dragpad needs on or off\n"); fflush(stdout); return; }
    cmd_dragpad(arg);
    return;
  }
  if (!strcmp(cmd, "dragarm")) {
    char *mime = next_token(&cursor);
    if (!mime) { printf("error dragarm needs mime base64\n"); fflush(stdout); return; }
    while (*cursor == ' ') cursor++;
    if (*cursor == '\0') { printf("error dragarm needs a base64 payload\n"); fflush(stdout); return; }
    cmd_dragarm(mime, cursor);
    return;
  }
  if (!strcmp(cmd, "dragto")) {
    char *xs = next_token(&cursor);
    char *ys = next_token(&cursor);
    char *mime = next_token(&cursor);
    if (!xs || !ys || !mime) { printf("error dragto needs x y mime base64\n"); fflush(stdout); return; }
    while (*cursor == ' ') cursor++;
    if (*cursor == '\0') { printf("error dragto needs a base64 payload\n"); fflush(stdout); return; }
    cmd_dragto(xs, ys, mime, cursor);
    return;
  }
  printf("error unknown command: %s\n", cmd);
  fflush(stdout);
}

#define LINE_SHRINK_THRESHOLD ((size_t)64 * 1024)

static char *linebuf;
static size_t linelen, linecap;
static int lineoverflow;

// grow linebuf to the given size
static void line_ensure(size_t need) {
  if (need <= linecap) return;
  size_t cap = linecap ? linecap : 256;
  while (cap < need) cap *= 2;
  char *grown = realloc(linebuf, cap);
  if (!grown) {
    fprintf(stderr, "rhizo-wlbridge: out of memory growing the stdin line buffer to %zu bytes\n", cap);
    exit(1);
  }
  linebuf = grown;
  linecap = cap;
}

// split stdin bytes into command lines
static void stdin_feed(const char *chunk, size_t n) {
  for (size_t i = 0; i < n; i++) {
    char ch = chunk[i];
    if (ch != '\n') {
      if (lineoverflow) continue;
      if (linelen + 1 > MAX_LINE) { lineoverflow = 1; continue; }
      line_ensure(linelen + 2);
      linebuf[linelen++] = ch;
      continue;
    }
    if (lineoverflow) {
      printf("error stdin line exceeds %zu bytes\n", (size_t)MAX_LINE);
      fflush(stdout);
      lineoverflow = 0;
    } else {
      line_ensure(linelen + 1);
      linebuf[linelen] = '\0';
      handle_line(linebuf);
    }
    linelen = 0;
    if (linecap > LINE_SHRINK_THRESHOLD) {
      char *shrunk = realloc(linebuf, LINE_SHRINK_THRESHOLD);
      if (shrunk) {
        linebuf = shrunk;
        linecap = LINE_SHRINK_THRESHOLD;
      }
    }
  }
}

// test the stdin line buffer and grow_buf
static int run_selftest_buffers(void) {
  size_t big = 200 * 1024;
  char *chunk = malloc(big + 1);
  if (!chunk) {
    fprintf(stderr, "selftest: out of memory building the fixture\n");
    return 1;
  }
  memset(chunk, 'x', big);
  chunk[big] = '\n';

  fflush(stdout);
  int saved_stdout = dup(STDOUT_FILENO);
  int devnull = open("/dev/null", O_WRONLY);
  if (saved_stdout < 0 || devnull < 0 || dup2(devnull, STDOUT_FILENO) < 0) {
    fprintf(stderr, "selftest: could not redirect stdout\n");
    free(chunk);
    if (saved_stdout >= 0) close(saved_stdout);
    if (devnull >= 0) close(devnull);
    return 1;
  }
  stdin_feed(chunk, big + 1);
  fflush(stdout);
  dup2(saved_stdout, STDOUT_FILENO);
  close(saved_stdout);
  close(devnull);
  free(chunk);

  int ok = 1;
  if (linecap > LINE_SHRINK_THRESHOLD) {
    fprintf(stderr,
            "selftest: linebuf is still %zu bytes after one %zu-byte line -- "
            "the shrink-back never ran\n", linecap, big);
    ok = 0;
  }
  if (linelen != 0) {
    fprintf(stderr, "selftest: linelen is %zu after a terminated line, expected 0\n", linelen);
    ok = 0;
  }

  size_t cap = 4;
  unsigned char *b = malloc(cap);
  if (!b) {
    fprintf(stderr, "selftest: out of memory building the grow_buf fixture\n");
    return 1;
  }
  b[0] = 0xAB;
  unsigned char *grown = grow_buf(b, &cap, 4096);
  if (!grown || cap < 4096 || grown[0] != 0xAB) {
    fprintf(stderr, "selftest: grow_buf(need=4096) gave cap=%zu ptr=%p byte0=%d\n",
            cap, (void *)grown, grown ? grown[0] : -1);
    ok = 0;
  }
  free(grown);

  if (ok) fprintf(stderr, "selftest: stdin buffer shrink and grow_buf both OK\n");
  return ok ? 0 : 1;
}

// set the termination flag
static void on_term_signal(int sig) {
  (void)sig;
  term_signal = 1;
}

// destroy the outgoing selection sources
static void release_selection(void) {
  if (!outgoing_head) return;
  releasing = 1;
  fprintf(stderr, "rhizo-wlbridge: releasing its selection before exit\n");
  while (outgoing_head) {
    struct outgoing *node = outgoing_head;
    outgoing_head = node->next;
    dc_source_destroy(node->src);
    if (node->held_fd >= 0) close(node->held_fd);
    free(node->mime);
    free(node->data);
    free(node);
  }
  wl_display_roundtrip(display);
}

// read commands from stdin
static void main_loop(void) {
  while (!should_quit && !term_signal) {
    short revents = 0;
    process_pending_drop();
    if (wl_pump(STDIN_FILENO, POLLIN, &revents, -1) < 0) { emit_conn_error(); return; }
    if (term_signal) return;
    process_pending_drop();
    if (!(revents & (POLLIN | POLLHUP))) continue;
    char chunk[4096];
    ssize_t n = read(STDIN_FILENO, chunk, sizeof(chunk));
    if (n < 0) {
      if (errno == EINTR) continue;
      fprintf(stderr, "rhizo-wlbridge: stdin read failed: %s\n", strerror(errno));
      return;
    }
    if (n == 0) break;
    stdin_feed(chunk, (size_t)n);
  }
}

// start rhizo-wlbridge and read stdin commands
int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "--selftest-base64")) return run_selftest_base64();
  if (argc > 1 && !strcmp(argv[1], "--selftest-buffers")) return run_selftest_buffers();

  const char *caps = NULL;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--caps") && i + 1 < argc) { caps = argv[++i]; continue; }
    if (!strcmp(argv[i], "--pad") && i + 1 < argc) {
      const char *mode = argv[++i];
      if (!strcmp(mode, "xdg")) { pad_mode_xdg = 1; continue; }
      if (!strcmp(mode, "layer")) { pad_mode_xdg = 0; continue; }
      fprintf(stderr, "rhizo-wlbridge: --pad wants xdg or layer, got %s\n", mode);
      return 2;
    }
    if (!strcmp(argv[i], "--selection") && i + 1 < argc) {
      const char *via = argv[++i];
      if (!strcmp(via, "pad")) { selection_via_pad = 1; continue; }
      if (!strcmp(via, "data-control")) { selection_via_pad = 0; continue; }
      fprintf(stderr, "rhizo-wlbridge: --selection wants pad or data-control, got %s\n", via);
      return 2;
    }
    fprintf(stderr, "rhizo-wlbridge: unknown argument %s\n", argv[i]);
    return 2;
  }
  if (!caps) {
    fprintf(stderr, "rhizo-wlbridge: --caps is required; pass an empty value to grant nothing\n");
    return 2;
  }
  cap_clipboard = caps_has(caps, "clipboard");
  cap_drag = caps_has(caps, "drag");
  cap_pointer = caps_has(caps, "pointer");
  if (selection_via_pad && !(cap_clipboard && cap_drag)) {
    fprintf(stderr, "rhizo-wlbridge: --selection pad needs --caps clipboard,drag\n");
    return 2;
  }

  signal(SIGPIPE, SIG_IGN);
  {
    sigset_t term;
    sigemptyset(&term);
    sigaddset(&term, SIGTERM);
    sigaddset(&term, SIGINT);
    sigaddset(&term, SIGHUP);
    sigprocmask(SIG_BLOCK, &term, &pump_sigmask);
    sigdelset(&pump_sigmask, SIGTERM);
    sigdelset(&pump_sigmask, SIGINT);
    sigdelset(&pump_sigmask, SIGHUP);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_term_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
  }
  display = wl_display_connect(NULL);
  if (!display) {
    fprintf(stderr, "rhizo-wlbridge: cannot connect to compositor (check WAYLAND_DISPLAY)\n");
    return 1;
  }

  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (wlr_manager) {
    manager = wlr_manager;
    if (ext_manager) ext_data_control_manager_v1_destroy(ext_manager);
  } else if (ext_manager) {
    manager = ext_manager;
    dc_ext = 1;
  }
  wlr_manager = NULL;
  ext_manager = NULL;
  if (cap_clipboard && !manager) {
    fprintf(stderr, "rhizo-wlbridge: compositor offers neither zwlr_ nor ext_data_control_manager_v1, "
                    "clipboard stays off for this bridge\n");
  }
  if (!seat) {
    fprintf(stderr, "rhizo-wlbridge: compositor has no wl_seat\n");
    return 1;
  }
  wl_display_roundtrip(display);

  if (manager) dc_get_device();


  if (data_manager) {
    dnd_device = wl_data_device_manager_get_data_device(data_manager, seat);
    wl_data_device_add_listener(dnd_device, &dnd_device_listener, NULL);
  }
  if (vp_manager) {
    if (output && pad_output_rect() &&
        zwlr_virtual_pointer_manager_v1_get_version(vp_manager) >= 2) {
      vp_pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output(
          vp_manager, seat, output);
      vp_on_output = 1;
    } else {
      vp_pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(vp_manager, seat);
    }
    zwlr_virtual_pointer_v1_motion_absolute(vp_pointer, now_ms(), 1, 1, 2, 2);
    zwlr_virtual_pointer_v1_frame(vp_pointer);
    wl_display_roundtrip(display);
  }

  wl_display_roundtrip(display);

  if (cap_clipboard && !manager && !selection_via_pad)
    printf("noclipboard the compositor offers neither zwlr_ nor ext_data_control_manager_v1\n");
  printf("ready\n");
  fflush(stdout);
  main_loop();

  release_selection();
  destroy_pad();
  wl_display_disconnect(display);
  return 0;
}
