#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <xkbcommon/xkbcommon.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *vp_manager;
static struct zwlr_virtual_pointer_v1 *pointer;
static struct zwp_virtual_keyboard_manager_v1 *kb_manager;
static struct zwp_virtual_keyboard_v1 *vkeyboard;

// bind the seat and the virtual pointer and keyboard managers
static void on_global(void *data, struct wl_registry *reg, uint32_t name,
                      const char *iface, uint32_t version) {
  (void)data; (void)version;
  if (!strcmp(iface, wl_seat_interface.name)) {
    seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
  } else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name)) {
    vp_manager = wl_registry_bind(reg, name,
                                  &zwlr_virtual_pointer_manager_v1_interface, 1);
  } else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name)) {
    kb_manager = wl_registry_bind(reg, name,
                                  &zwp_virtual_keyboard_manager_v1_interface, 1);
  }
}
// ignore a removed registry global
static void on_global_remove(void *d, struct wl_registry *r, uint32_t n) {
  (void)d; (void)r; (void)n;
}
static const struct wl_registry_listener registry_listener = {
  .global = on_global, .global_remove = on_global_remove,
};

// return the monotonic time in milliseconds
static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

// upload a keymap string to the virtual keyboard
static int upload_keymap(const char *text, size_t len) {
  if (!vkeyboard) {
    fprintf(stderr, "wlr-inject: no virtual keyboard to upload a keymap to\n");
    return -1;
  }
  int fd = memfd_create("rhizo-wlr-inject-keymap", MFD_CLOEXEC);
  if (fd < 0) { perror("wlr-inject: memfd_create"); return -1; }
  if (ftruncate(fd, (off_t)(len + 1)) < 0) {
    perror("wlr-inject: ftruncate"); close(fd); return -1;
  }
  void *map = mmap(NULL, len + 1, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (map == MAP_FAILED) { perror("wlr-inject: mmap"); close(fd); return -1; }
  memcpy(map, text, len);
  ((char *)map)[len] = '\0';
  munmap(map, len + 1);
  zwp_virtual_keyboard_v1_keymap(vkeyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
                                 fd, (uint32_t)(len + 1));
  close(fd);
  return 0;
}

// upload a default keymap
static int upload_default_keymap(void) {
  struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  if (!ctx) { fprintf(stderr, "wlr-inject: xkb_context_new failed\n"); return -1; }
  struct xkb_rule_names names = {
    .rules = NULL, .model = NULL, .layout = "us", .variant = NULL, .options = NULL,
  };
  struct xkb_keymap *km = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (!km) {
    fprintf(stderr, "wlr-inject: xkb_keymap_new_from_names(us) failed\n");
    xkb_context_unref(ctx);
    return -1;
  }
  char *text = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
  xkb_keymap_unref(km);
  xkb_context_unref(ctx);
  if (!text) {
    fprintf(stderr, "wlr-inject: xkb_keymap_get_as_string failed\n");
    return -1;
  }
  int rc = upload_keymap(text, strlen(text));
  free(text);
  return rc;
}

// upload a keymap file
static int upload_keymap_file(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0) {
    fprintf(stderr, "wlr-inject: keymap: cannot stat %s: %s\n", path, strerror(errno));
    return -1;
  }
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "wlr-inject: keymap: cannot open %s\n", path); return -1; }
  char *buf = malloc((size_t)st.st_size + 1);
  if (!buf) { fclose(f); fprintf(stderr, "wlr-inject: keymap: out of memory\n"); return -1; }
  size_t got = fread(buf, 1, (size_t)st.st_size, f);
  fclose(f);
  if (got != (size_t)st.st_size) {
    fprintf(stderr, "wlr-inject: keymap: short read on %s\n", path);
    free(buf);
    return -1;
  }
  int rc = upload_keymap(buf, got);
  free(buf);
  return rc;
}

// read commands and send input events
int main(int argc, char **argv) {
  const char *fifo_path = NULL;
  const char *listen_path = NULL;
  const char *keymap_path = NULL;
  int want_keyboard = 1;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--fifo") && i + 1 < argc) {
      fifo_path = argv[++i];
    } else if (!strcmp(argv[i], "--listen") && i + 1 < argc) {
      listen_path = argv[++i];
    } else if (!strcmp(argv[i], "--keymap") && i + 1 < argc) {
      keymap_path = argv[++i];
    } else if (!strcmp(argv[i], "--no-keyboard")) {
      want_keyboard = 0;
    } else {
      fprintf(stderr, "wlr-inject: unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  struct wl_display *display = wl_display_connect(NULL);
  if (!display) { fprintf(stderr, "wlr-inject: cannot connect to compositor\n"); return 1; }

  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);

  if (!vp_manager) {
    fprintf(stderr, "wlr-inject: compositor has no zwlr_virtual_pointer_manager_v1\n");
    return 1;
  }
  pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(vp_manager, seat);
  if (!pointer) { fprintf(stderr, "wlr-inject: create_virtual_pointer failed\n"); return 1; }
  zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), 1, 1, 2, 2);
  zwlr_virtual_pointer_v1_frame(pointer);

  if (!want_keyboard) {
    fprintf(stderr, "wlr-inject: --no-keyboard, pointer only\n");
  } else if (!kb_manager) {
    fprintf(stderr, "wlr-inject: compositor has no zwp_virtual_keyboard_manager_v1 "
                    "-- keyboard commands (key/keymap/mods) will fail\n");
  } else if (!seat) {
    fprintf(stderr, "wlr-inject: no wl_seat bound -- no virtual keyboard\n");
  } else {
    vkeyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(kb_manager, seat);
    if (!vkeyboard) {
      fprintf(stderr, "wlr-inject: create_virtual_keyboard failed\n");
    } else if (keymap_path ? upload_keymap_file(keymap_path) != 0
                          : upload_default_keymap() != 0) {
      fprintf(stderr, "wlr-inject: keymap upload failed -- "
                      "key/mods commands will error with no_keymap\n");
    }
  }

  wl_display_flush(display);
  fprintf(stderr, "wlr-inject: virtual pointer live%s\n",
          vkeyboard ? " + virtual keyboard live" : "");
  printf("ready\n");
  fflush(stdout);

  int listen_fd = -1;
  if (listen_path) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", listen_path);
    unlink(listen_path);
    listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_fd < 0 || bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        chmod(listen_path, 0666) < 0 || listen(listen_fd, 4) < 0) {
      fprintf(stderr, "wlr-inject: cannot listen on %s: %s\n", listen_path, strerror(errno));
      return 1;
    }
    fprintf(stderr, "wlr-inject: listening on %s\n", listen_path);
  }

  char line[512];
  FILE *in = stdin;
  for (;;) {
  if (listen_fd >= 0) {
    int conn;
    for (;;) {
      struct pollfd pfd = {listen_fd, POLLIN, 0};
      wl_display_flush(display);
      if (wl_display_dispatch_pending(display) < 0) return 1;
      if (poll(&pfd, 1, 200) > 0 && (pfd.revents & POLLIN)) break;
    }
    conn = accept(listen_fd, NULL, NULL);
    if (conn < 0) continue;
    in = fdopen(conn, "r");
    if (!in) { close(conn); in = stdin; continue; }
  } else if (fifo_path) {
    while (access(fifo_path, F_OK) != 0) {
      wl_display_flush(display);
      if (wl_display_dispatch_pending(display) < 0) return 1;
      usleep(200000);
    }
    if (!freopen(fifo_path, "r", stdin)) {
      usleep(200000);
      continue;
    }
    in = stdin;
  }
  while (fgets(line, sizeof(line), in)) {
    unsigned x, y, w, h, code, state;
    double value;
    char axisc[8];
    int steps;
    char path[256];
    unsigned mods_depressed, mods_latched, mods_locked, group;
    if (sscanf(line, "abs %u %u %u %u", &x, &y, &w, &h) == 4) {
      zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), x, y, w, h);
      zwlr_virtual_pointer_v1_frame(pointer);
    } else if (sscanf(line, "btn %u %u", &code, &state) == 2) {
      zwlr_virtual_pointer_v1_button(pointer, now_ms(), code, state);
      zwlr_virtual_pointer_v1_frame(pointer);
    } else if (sscanf(line, "axis %lf", &value) == 1) {
      zwlr_virtual_pointer_v1_axis(pointer, now_ms(),
                                   WL_POINTER_AXIS_VERTICAL_SCROLL,
                                   wl_fixed_from_double(value));
      zwlr_virtual_pointer_v1_frame(pointer);
    } else if (sscanf(line, "axis_h %lf", &value) == 1) {
      zwlr_virtual_pointer_v1_axis(pointer, now_ms(),
                                   WL_POINTER_AXIS_HORIZONTAL_SCROLL,
                                   wl_fixed_from_double(value));
      zwlr_virtual_pointer_v1_frame(pointer);
    } else if (sscanf(line, "axis_disc %7s %d", axisc, &steps) == 2 &&
               (axisc[0] == 'v' || axisc[0] == 'h') && axisc[1] == '\0') {
      uint32_t axis = (axisc[0] == 'v') ? WL_POINTER_AXIS_VERTICAL_SCROLL
                                        : WL_POINTER_AXIS_HORIZONTAL_SCROLL;
      zwlr_virtual_pointer_v1_axis_discrete(pointer, now_ms(), axis,
                                            wl_fixed_from_double(steps * 10.0),
                                            steps);
      zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
      zwlr_virtual_pointer_v1_frame(pointer);
    } else if (sscanf(line, "key %u %u", &code, &state) == 2) {
      if (!vkeyboard) {
        fprintf(stderr, "wlr-inject: key: no virtual keyboard\n");
      } else {
        zwp_virtual_keyboard_v1_key(vkeyboard, now_ms(), code, state);
      }
    } else if (sscanf(line, "keymap %255s", path) == 1) {
      upload_keymap_file(path);
    } else if (sscanf(line, "mods %u %u %u %u", &mods_depressed, &mods_latched,
                      &mods_locked, &group) == 4) {
      if (!vkeyboard) {
        fprintf(stderr, "wlr-inject: mods: no virtual keyboard\n");
      } else {
        zwp_virtual_keyboard_v1_modifiers(vkeyboard, mods_depressed,
                                          mods_latched, mods_locked, group);
      }
    } else if (!strncmp(line, "ping", 4)) {
      printf("pong\n");
    } else {
      fprintf(stderr, "wlr-inject: unknown command: %s", line);
    }
    fflush(stdout);
    wl_display_flush(display);
    if (wl_display_dispatch_pending(display) < 0) break;
  }
  if (listen_fd >= 0) {
    fclose(in);
    in = stdin;
    continue;
  }
  if (!fifo_path) break;
  clearerr(stdin);
  }
  if (vkeyboard) zwp_virtual_keyboard_v1_destroy(vkeyboard);
  zwlr_virtual_pointer_v1_destroy(pointer);
  wl_display_disconnect(display);
  return 0;
}
