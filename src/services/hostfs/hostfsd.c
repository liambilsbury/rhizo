// serve a host directory over a /dev/fuse descriptor
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/fuse.h>
#include <linux/seccomp.h>

#include "../fuse-wire/fuse_wire.h"


// command line settings
struct config {
    int fd;
    const char *root;
    uint32_t uid;
    uint32_t gid;
    uint32_t file_mode;
    uint32_t dir_mode;
    int foreground;
    const char *log_path;
};

static struct config g_cfg = {
    .fd = -1,
    .root = NULL,
    .uid = 1023,
    .gid = 1023,
    .file_mode = 0664,
    .dir_mode = 0775,
    .foreground = 0,
    .log_path = NULL,
};

static int g_fuse_fd = -1;
static FILE *g_log = NULL;
static volatile sig_atomic_t g_destroy_requested = 0;

#define RHIZO_FUSE_MINOR 31

#define MAX_WRITE_SIZE (128u * 1024u)
#define IN_BUF_SIZE ((MAX_WRITE_SIZE + 4096u) > FUSE_MIN_READ_BUFFER \
                         ? (MAX_WRITE_SIZE + 4096u) \
                         : FUSE_MIN_READ_BUFFER)
#define MAX_DIR_BUF (64u * 1024u)
#define NAME_MAX_LEN 255

static _Alignas(8) uint8_t g_inbuf[IN_BUF_SIZE];


static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

// write a log line with a level
static void logf_line(const char *level, const char *fmt, va_list ap) {
    FILE *out = g_log ? g_log : stderr;
    pthread_mutex_lock(&g_log_lock);
    fprintf(out, "[rhizo-hostfsd] %s: ", level);
    vfprintf(out, fmt, ap);
    fputc('\n', out);
    fflush(out);
    pthread_mutex_unlock(&g_log_lock);
}

// log an info message
static void rz_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    logf_line("info", fmt, ap);
    va_end(ap);
}

static void logf_err(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    logf_line("error", fmt, ap);
    va_end(ap);
}


// inode table entry
struct inode {
    uint64_t nodeid;
    dev_t dev;
    ino_t ino;
    uint64_t refcount;
    int path_fd;
    int is_dir;
    struct inode *hash_next;
    struct inode *nodeid_next;
};

#define INODE_HASH_SIZE 1024
static struct inode *g_hash[INODE_HASH_SIZE];

static struct inode *g_nodeid_hash[INODE_HASH_SIZE];
static uint64_t g_next_nodeid = FUSE_ROOT_ID + 1;
static uint32_t g_inodes_live = 0;

static struct inode *g_root = NULL;


#define FD_TRANSIENT_RESERVE 16u
#define MAX_HANDLES_CEILING 1024u
#define MAX_INODES_CEILING 65536u

static uint32_t g_max_handles = 64;
static uint32_t g_max_inodes = 256;

// size the handle and inode tables from RLIMIT_NOFILE
static void budget_init(void) {
    struct rlimit rl;
    uint64_t soft = 1024;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        soft = (rl.rlim_cur == RLIM_INFINITY) ? (uint64_t)1 << 20 : (uint64_t)rl.rlim_cur;
    }
    uint64_t budget = soft > FD_TRANSIENT_RESERVE ? soft - FD_TRANSIENT_RESERVE : 8;

    uint64_t handles = budget / 4;
    if (handles < 8) handles = 8;
    if (handles > MAX_HANDLES_CEILING) handles = MAX_HANDLES_CEILING;
    g_max_handles = (uint32_t)handles;

    uint64_t inodes = budget > handles ? budget - handles : 16;
    if (inodes < 16) inodes = 16;
    if (inodes > MAX_INODES_CEILING) inodes = MAX_INODES_CEILING;
    g_max_inodes = (uint32_t)inodes;
}

// raise RLIMIT_NOFILE to its hard limit
static void raise_nofile(void) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) return;
    if (rl.rlim_cur == rl.rlim_max) return;
    rlim_t was = rl.rlim_cur;
    rl.rlim_cur = rl.rlim_max;
    if (setrlimit(RLIMIT_NOFILE, &rl) == 0) {
        rz_log("RLIMIT_NOFILE raised from %ju to its hard limit %ju",
             (uintmax_t)was, (uintmax_t)rl.rlim_max);
    }
}

// return the hash bucket of a device and inode
static unsigned inode_hash_idx(dev_t dev, ino_t ino) {
    uint64_t h = (uint64_t)dev * 1099511628211ULL + (uint64_t)ino;
    h ^= h >> 33;
    return (unsigned)(h % INODE_HASH_SIZE);
}

// find an inode in the device and inode hash, or NULL
static struct inode *inode_hash_find(dev_t dev, ino_t ino) {
    unsigned idx = inode_hash_idx(dev, ino);
    for (struct inode *n = g_hash[idx]; n; n = n->hash_next) {
        if (n->dev == dev && n->ino == ino) return n;
    }
    return NULL;
}

// add an inode to the device and inode hash
static void inode_hash_insert(struct inode *n) {
    unsigned idx = inode_hash_idx(n->dev, n->ino);
    n->hash_next = g_hash[idx];
    g_hash[idx] = n;
}

// remove an inode from the device and inode hash
static void inode_hash_remove(struct inode *n) {
    unsigned idx = inode_hash_idx(n->dev, n->ino);
    struct inode **pp = &g_hash[idx];
    while (*pp) {
        if (*pp == n) { *pp = n->hash_next; return; }
        pp = &(*pp)->hash_next;
    }
}

// return the hash bucket of a node id
static unsigned nodeid_hash_idx(uint64_t nodeid) {
    uint64_t h = nodeid * 1099511628211ULL;
    h ^= h >> 29;
    return (unsigned)(h % INODE_HASH_SIZE);
}

// add an inode to the node id hash
static void nodeid_hash_insert(struct inode *n) {
    unsigned idx = nodeid_hash_idx(n->nodeid);
    n->nodeid_next = g_nodeid_hash[idx];
    g_nodeid_hash[idx] = n;
}

// remove an inode from the node id hash
static void nodeid_hash_remove(struct inode *n) {
    unsigned idx = nodeid_hash_idx(n->nodeid);
    struct inode **pp = &g_nodeid_hash[idx];
    while (*pp) {
        if (*pp == n) { *pp = n->nodeid_next; return; }
        pp = &(*pp)->nodeid_next;
    }
}

// find an inode by node id, or NULL
static struct inode *inode_get(uint64_t nodeid) {
    if (nodeid == 0) return NULL;
    for (struct inode *n = g_nodeid_hash[nodeid_hash_idx(nodeid)]; n; n = n->nodeid_next) {
        if (n->nodeid == nodeid) return n;
    }
    return NULL;
}

// add an O_PATH fd to the inode table
static struct inode *inode_register(dev_t dev, ino_t ino, int path_fd, int is_dir, int *err) {
    struct inode *existing = inode_hash_find(dev, ino);
    if (existing) {
        close(path_fd);
        existing->refcount++;
        return existing;
    }
    if (g_inodes_live >= g_max_inodes) {
        close(path_fd);
        *err = EMFILE;
        return NULL;
    }
    struct inode *n = calloc(1, sizeof(*n));
    if (!n) {
        close(path_fd);
        logf_err("out of memory allocating an inode: refusing the lookup");
        *err = ENOMEM;
        return NULL;
    }
    n->nodeid = g_next_nodeid++;
    n->dev = dev;
    n->ino = ino;
    n->refcount = 1;
    n->path_fd = path_fd;
    n->is_dir = is_dir;
    inode_hash_insert(n);
    nodeid_hash_insert(n);
    g_inodes_live++;
    return n;
}

// drop n references to the inode
static void inode_forget(uint64_t nodeid, uint64_t n) {
    if (nodeid == FUSE_ROOT_ID) return;
    struct inode *ino = inode_get(nodeid);
    if (!ino) return;
    if (n >= ino->refcount) {
        inode_hash_remove(ino);
        nodeid_hash_remove(ino);
        if (ino->path_fd >= 0) close(ino->path_fd);
        free(ino);
        g_inodes_live--;
    } else {
        ino->refcount -= n;
    }
}

// open the root directory and create its inode
static void inode_table_init(const char *root_path) {
    budget_init();
    int fd = open(root_path, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        logf_err("cannot open --root %s: %s", root_path, strerror(errno));
        exit(1);
    }
    struct stat st;
    if (fstatat(fd, "", &st, AT_EMPTY_PATH) < 0) {
        logf_err("cannot stat --root %s: %s", root_path, strerror(errno));
        exit(1);
    }
    struct inode *n = calloc(1, sizeof(*n));
    if (!n) { logf_err("out of memory"); exit(1); }
    n->nodeid = FUSE_ROOT_ID;
    n->dev = st.st_dev;
    n->ino = st.st_ino;
    n->refcount = 1;
    n->path_fd = fd;
    n->is_dir = 1;
    inode_hash_insert(n);
    nodeid_hash_insert(n);
    g_inodes_live = 1;
    g_next_nodeid = FUSE_ROOT_ID + 1;
    g_root = n;
}


// validate a path component name
static int name_ok(const char *name) {
    if (!name || name[0] == '\0') return 0;
    if (strchr(name, '/') != NULL) return 0;
    if (strcmp(name, ".") == 0) return 0;
    if (strcmp(name, "..") == 0) return 0;
    if (strlen(name) > NAME_MAX_LEN) return 0;
    return 1;
}

// format the /proc/self/fd path of fd
static void fd_procpath(int fd, char *buf, size_t buflen) {
    snprintf(buf, buflen, "/proc/self/fd/%d", fd);
}

// reopen a path descriptor through /proc with the given flags
static int reopen_via_procpath(int path_fd, int flags, mode_t mode) {
    char buf[64];
    fd_procpath(path_fd, buf, sizeof(buf));
    return open(buf, flags, mode);
}

// look up a name under a parent inode
static int resolve_and_register(struct inode *parent, const char *name,
                                 struct inode **out, struct stat *st_out) {
    if (!parent->is_dir) return ENOTDIR;
    if (!name_ok(name)) return ENOENT;

    int fd = openat(parent->path_fd, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno;

    struct stat st;
    if (fstatat(fd, "", &st, AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW) < 0) {
        int e = errno;
        close(fd);
        return e;
    }
    if (S_ISLNK(st.st_mode)) {
        close(fd);
        return ENOENT;
    }
    if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) {
        close(fd);
        return ENOENT;
    }

    int err = 0;
    struct inode *n = inode_register(st.st_dev, st.st_ino, fd, S_ISDIR(st.st_mode), &err);
    if (!n) return err;
    *out = n;
    *st_out = st;
    return 0;
}


// fill a fuse_attr from a stat
static void fill_fuse_attr(struct fuse_attr *a, const struct inode *n, const struct stat *st) {
    memset(a, 0, sizeof(*a));
    a->ino = n->nodeid;
    a->size = (uint64_t)st->st_size;
    a->blocks = (uint64_t)st->st_blocks;
    a->atime = (uint64_t)st->st_atim.tv_sec;
    a->atimensec = (uint32_t)st->st_atim.tv_nsec;
    a->mtime = (uint64_t)st->st_mtim.tv_sec;
    a->mtimensec = (uint32_t)st->st_mtim.tv_nsec;
    a->ctime = (uint64_t)st->st_ctim.tv_sec;
    a->ctimensec = (uint32_t)st->st_ctim.tv_nsec;
    uint32_t perm = (n->is_dir ? g_cfg.dir_mode : g_cfg.file_mode) & 07777;
    a->mode = (n->is_dir ? (uint32_t)S_IFDIR : (uint32_t)S_IFREG) | perm;
    a->nlink = (uint32_t)st->st_nlink;
    a->uid = g_cfg.uid;
    a->gid = g_cfg.gid;
    a->rdev = 0;
    a->blksize = (uint32_t)st->st_blksize;
    a->flags = 0;
}

// set the entry and attribute timeouts to zero
static void set_entry_times(struct fuse_entry_out *eo) {
    eo->entry_valid = 0;
    eo->entry_valid_nsec = 0;
    eo->attr_valid = 0;
    eo->attr_valid_nsec = 0;
}


static pthread_mutex_t g_fuse_write_lock = PTHREAD_MUTEX_INITIALIZER;

// send a reply to /dev/fuse
static void raw_reply(uint64_t unique, int32_t error, const void *data, uint32_t data_len) {
    struct iovec body = { .iov_base = (void *)data, .iov_len = data_len };

    pthread_mutex_lock(&g_fuse_write_lock);
    int rc = fuse_wire_reply(g_fuse_fd, unique, error, &body, data_len > 0 ? 1 : 0);
    int err = errno;
    pthread_mutex_unlock(&g_fuse_write_lock);

    if (rc == 0) return;
    if (err == ENOENT) {
        return;
    }
    logf_err("write(/dev/fuse) failed for unique=%" PRIu64 ": %s", unique, strerror(err));
}

// reply with success and data
static void reply_ok(uint64_t unique, const void *data, uint32_t len) {
    raw_reply(unique, 0, data, len);
}

// reply with an error number
static void reply_err(uint64_t unique, int errnum) {
    raw_reply(unique, -errnum, NULL, 0);
}


enum handle_kind { HANDLE_FREE = 0, HANDLE_FILE, HANDLE_DIR };

#define DIR_OFF_RING 256

// open file or directory handle
struct handle {
    enum handle_kind kind;
    uint32_t gen;
    int fd;
    DIR *dirp;
    uint64_t *offs;
    uint32_t off_count;
    int32_t next_free;
    uint32_t inflight;
    int closing;
};

static pthread_mutex_t g_handle_lock = PTHREAD_MUTEX_INITIALIZER;

static struct handle *g_handles = NULL;
static uint32_t g_handles_cap = 0;
static uint32_t g_handles_used = 0;
static int32_t g_handle_free = -1;
static uint32_t g_next_gen = 1;

// allocate a handle of a kind
static struct handle *handle_alloc(enum handle_kind kind, uint64_t *fh_out) {
    pthread_mutex_lock(&g_handle_lock);
    int32_t idx;
    if (g_handle_free >= 0) {
        idx = g_handle_free;
        g_handle_free = g_handles[idx].next_free;
    } else {
        if (g_handles_used >= g_max_handles) { pthread_mutex_unlock(&g_handle_lock); return NULL; }
        if (g_handles_used == g_handles_cap) {
            uint32_t newcap = g_handles_cap ? g_handles_cap * 2 : 16;
            if (newcap > g_max_handles) newcap = g_max_handles;
            struct handle *grown = realloc(g_handles, (size_t)newcap * sizeof(*grown));
            if (!grown) { pthread_mutex_unlock(&g_handle_lock); return NULL; }
            memset(grown + g_handles_cap, 0, (size_t)(newcap - g_handles_cap) * sizeof(*grown));
            g_handles = grown;
            g_handles_cap = newcap;
        }
        idx = (int32_t)g_handles_used++;
    }
    struct handle *h = &g_handles[idx];
    h->kind = kind;
    h->gen = g_next_gen++;
    if (g_next_gen == 0) g_next_gen = 1;
    h->fd = -1;
    h->dirp = NULL;
    h->offs = NULL;
    h->off_count = 0;
    h->next_free = -1;
    h->inflight = 0;
    h->closing = 0;
    *fh_out = ((uint64_t)h->gen << 32) | (uint32_t)idx;
    pthread_mutex_unlock(&g_handle_lock);
    return h;
}

// return the handle for a file handle number
static struct handle *handle_get(uint64_t fh, enum handle_kind kind) {
    uint32_t idx = (uint32_t)(fh & 0xffffffffu);
    uint32_t gen = (uint32_t)(fh >> 32);
    pthread_mutex_lock(&g_handle_lock);
    if (idx >= g_handles_used) { pthread_mutex_unlock(&g_handle_lock); return NULL; }
    struct handle *h = &g_handles[idx];
    if (h->kind != kind || h->gen != gen) { pthread_mutex_unlock(&g_handle_lock); return NULL; }
    pthread_mutex_unlock(&g_handle_lock);
    return h;
}

// close the handle and free its slot
static void handle_put(uint64_t fh) {
    uint32_t idx = (uint32_t)(fh & 0xffffffffu);
    pthread_mutex_lock(&g_handle_lock);
    struct handle *h = &g_handles[idx];
    if (h->kind == HANDLE_FILE && h->fd >= 0) close(h->fd);
    if (h->kind == HANDLE_DIR && h->dirp) closedir(h->dirp);
    free(h->offs);
    h->kind = HANDLE_FREE;
    h->fd = -1;
    h->dirp = NULL;
    h->offs = NULL;
    h->off_count = 0;
    h->inflight = 0;
    h->closing = 0;
    h->next_free = g_handle_free;
    g_handle_free = (int32_t)idx;
    pthread_mutex_unlock(&g_handle_lock);
}

// return whether a directory offset was issued by this handle
static int dir_off_issued(const struct handle *h, uint64_t off) {
    for (uint32_t i = 0; i < h->off_count; i++) {
        if (h->offs[i] == off) return 1;
    }
    return 0;
}

// record a directory offset in the ring
static void dir_off_record(struct handle *h, uint64_t off) {
    if (!h->offs) {
        h->offs = malloc(DIR_OFF_RING * sizeof(*h->offs));
        if (!h->offs) return;
    }
    if (h->off_count < DIR_OFF_RING) h->offs[h->off_count++] = off;
}


// reply to the FUSE_INIT request
static void op_init(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    struct fuse_init_in kin;
    memset(&kin, 0, sizeof(kin));
    memcpy(&kin, body, body_len < sizeof(kin) ? body_len : sizeof(kin));

    struct fuse_init_out out;
    memset(&out, 0, sizeof(out));

    if (kin.major != FUSE_KERNEL_VERSION) {
        out.major = FUSE_KERNEL_VERSION;
        out.minor = 0;
        reply_ok(in->unique, &out, sizeof(out));
        return;
    }

    uint32_t minor = kin.minor < RHIZO_FUSE_MINOR ? kin.minor : RHIZO_FUSE_MINOR;

    out.major = FUSE_KERNEL_VERSION;
    out.minor = minor;
    out.max_readahead = kin.max_readahead < (128u * 1024u) ? kin.max_readahead : (128u * 1024u);
    out.flags = 0;
    out.max_background = 0;
    out.congestion_threshold = 0;
    out.max_write = MAX_WRITE_SIZE;
    out.time_gran = 1;
    out.max_pages = 0;
    out.map_alignment = 0;
    out.flags2 = 0;

    rz_log("INIT: kernel major=%u minor=%u -> negotiated major=%u minor=%u, max_write=%u",
         kin.major, kin.minor, out.major, out.minor, out.max_write);

    reply_ok(in->unique, &out, sizeof(out));
}

// mark the daemon to exit
static void op_destroy(const struct fuse_in_header *in) {
    rz_log("DESTROY received, will exit after replying");
    reply_ok(in->unique, NULL, 0);
    g_destroy_requested = 1;
}

// resolve a name under a directory inode
static void op_lookup(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    const char *name = (const char *)body;
    if (body_len == 0 || memchr(name, '\0', body_len) == NULL) {
        reply_err(in->unique, EINVAL);
        return;
    }
    struct inode *parent = inode_get(in->nodeid);
    if (!parent) { reply_err(in->unique, ENOENT); return; }

    struct inode *child;
    struct stat st;
    int rc = resolve_and_register(parent, name, &child, &st);
    if (rc != 0) { reply_err(in->unique, rc); return; }

    struct fuse_entry_out eo;
    memset(&eo, 0, sizeof(eo));
    eo.nodeid = child->nodeid;
    eo.generation = 0;
    set_entry_times(&eo);
    fill_fuse_attr(&eo.attr, child, &st);
    reply_ok(in->unique, &eo, sizeof(eo));
}

// release lookups on an inode
static void op_forget(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    (void)in;
    if (body_len < sizeof(struct fuse_forget_in)) return;
    const struct fuse_forget_in *fi = (const struct fuse_forget_in *)body;
    inode_forget(in->nodeid, fi->nlookup);
}

// release lookups on a list of inodes
static void op_batch_forget(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    (void)in;
    if (body_len < sizeof(struct fuse_batch_forget_in)) return;
    const struct fuse_batch_forget_in *bf = (const struct fuse_batch_forget_in *)body;
    const uint8_t *p = body + sizeof(*bf);
    uint32_t remaining = body_len - (uint32_t)sizeof(*bf);
    for (uint32_t i = 0; i < bf->count && remaining >= sizeof(struct fuse_forget_one); i++) {
        const struct fuse_forget_one *fo = (const struct fuse_forget_one *)p;
        inode_forget(fo->nodeid, fo->nlookup);
        p += sizeof(*fo);
        remaining -= (uint32_t)sizeof(*fo);
    }
}

// fill an attribute reply from the inode
static int do_getattr(struct inode *n, struct fuse_attr_out *out) {
    struct stat st;
    if (fstatat(n->path_fd, "", &st, AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW) < 0) return errno;
    memset(out, 0, sizeof(*out));
    out->attr_valid = 0;
    out->attr_valid_nsec = 0;
    fill_fuse_attr(&out->attr, n, &st);
    return 0;
}

// reply with the inode attributes
static void op_getattr(const struct fuse_in_header *in) {
    struct inode *n = inode_get(in->nodeid);
    if (!n) { reply_err(in->unique, ENOENT); return; }
    struct fuse_attr_out out;
    int rc = do_getattr(n, &out);
    if (rc != 0) { reply_err(in->unique, rc); return; }
    reply_ok(in->unique, &out, sizeof(out));
}

// set the attributes of an inode
static void op_setattr(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len < sizeof(struct fuse_setattr_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_setattr_in *sa = (const struct fuse_setattr_in *)body;
    struct inode *n = inode_get(in->nodeid);
    if (!n) { reply_err(in->unique, ENOENT); return; }

    char procpath[64];
    fd_procpath(n->path_fd, procpath, sizeof(procpath));

    if (sa->valid & FATTR_SIZE) {
        if (n->is_dir) { reply_err(in->unique, EISDIR); return; }
        int wfd = open(procpath, O_WRONLY);
        if (wfd < 0) { reply_err(in->unique, errno); return; }
        if (ftruncate(wfd, (off_t)sa->size) < 0) {
            int e = errno;
            close(wfd);
            reply_err(in->unique, e);
            return;
        }
        close(wfd);
    }

    if (sa->valid & FATTR_MODE) {
        if (chmod(procpath, sa->mode & 07777) < 0) {
            reply_err(in->unique, errno);
            return;
        }
    }

    if (sa->valid & (FATTR_ATIME | FATTR_MTIME)) {
        struct timespec ts[2];
        ts[0].tv_sec = 0; ts[0].tv_nsec = UTIME_OMIT;
        ts[1].tv_sec = 0; ts[1].tv_nsec = UTIME_OMIT;
        if (sa->valid & FATTR_ATIME) {
            if (sa->valid & FATTR_ATIME_NOW) { ts[0].tv_nsec = UTIME_NOW; }
            else { ts[0].tv_sec = (time_t)sa->atime; ts[0].tv_nsec = sa->atimensec; }
        }
        if (sa->valid & FATTR_MTIME) {
            if (sa->valid & FATTR_MTIME_NOW) { ts[1].tv_nsec = UTIME_NOW; }
            else { ts[1].tv_sec = (time_t)sa->mtime; ts[1].tv_nsec = sa->mtimensec; }
        }
        if (utimensat(AT_FDCWD, procpath, ts, 0) < 0) {
            reply_err(in->unique, errno);
            return;
        }
    }

    struct fuse_attr_out out;
    int rc = do_getattr(n, &out);
    if (rc != 0) { reply_err(in->unique, rc); return; }
    reply_ok(in->unique, &out, sizeof(out));
}

// mask the kernel open flags
static int sanitize_open_flags(uint32_t flags) {
    int real = (int)(flags & O_ACCMODE);
    if (flags & O_APPEND) real |= O_APPEND;
    if (flags & O_TRUNC) real |= O_TRUNC;
    real |= O_CLOEXEC;
    return real;
}

// open a file and return its handle
static void op_open(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len < sizeof(struct fuse_open_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_open_in *oi = (const struct fuse_open_in *)body;
    struct inode *n = inode_get(in->nodeid);
    if (!n) { reply_err(in->unique, ENOENT); return; }
    if (n->is_dir) { reply_err(in->unique, EISDIR); return; }

    int fd = reopen_via_procpath(n->path_fd, sanitize_open_flags(oi->flags), 0);
    if (fd < 0) { reply_err(in->unique, errno); return; }

    uint64_t fh;
    struct handle *h = handle_alloc(HANDLE_FILE, &fh);
    if (!h) { close(fd); reply_err(in->unique, EMFILE); return; }
    h->fd = fd;

    struct fuse_open_out out;
    memset(&out, 0, sizeof(out));
    out.fh = fh;
    out.open_flags = FOPEN_DIRECT_IO;
    reply_ok(in->unique, &out, sizeof(out));
}

// create and open a file
static void op_create(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len <= sizeof(struct fuse_create_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_create_in *ci = (const struct fuse_create_in *)body;
    const char *name = (const char *)(body + sizeof(*ci));
    uint32_t name_len = body_len - (uint32_t)sizeof(*ci);
    if (memchr(name, '\0', name_len) == NULL) { reply_err(in->unique, EINVAL); return; }

    struct inode *parent = inode_get(in->nodeid);
    if (!parent) { reply_err(in->unique, ENOENT); return; }
    if (!parent->is_dir) { reply_err(in->unique, ENOTDIR); return; }
    if (!name_ok(name)) { reply_err(in->unique, EACCES); return; }

    int real_flags = (int)(ci->flags & (O_ACCMODE | O_APPEND | O_TRUNC | O_EXCL))
                     | O_CREAT | O_NOFOLLOW | O_CLOEXEC;
    int fd = openat(parent->path_fd, name, real_flags, g_cfg.file_mode & 07777);
    if (fd < 0) {
        reply_err(in->unique, errno == ELOOP ? EACCES : errno);
        return;
    }

    uint64_t fh;
    struct handle *h = handle_alloc(HANDLE_FILE, &fh);
    if (!h) { close(fd); reply_err(in->unique, EMFILE); return; }
    h->fd = fd;

    struct inode *child;
    struct stat st;
    int rc = resolve_and_register(parent, name, &child, &st);
    if (rc != 0) { handle_put(fh); reply_err(in->unique, rc); return; }

    struct {
        struct fuse_entry_out eo;
        struct fuse_open_out oo;
    } out;
    memset(&out, 0, sizeof(out));
    out.eo.nodeid = child->nodeid;
    set_entry_times(&out.eo);
    fill_fuse_attr(&out.eo.attr, child, &st);
    out.oo.fh = fh;
    out.oo.open_flags = FOPEN_DIRECT_IO;
    reply_ok(in->unique, &out, sizeof(out));
}

// create a directory
static void op_mkdir(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len <= sizeof(struct fuse_mkdir_in)) { reply_err(in->unique, EINVAL); return; }
    const char *name = (const char *)(body + sizeof(struct fuse_mkdir_in));
    uint32_t name_len = body_len - (uint32_t)sizeof(struct fuse_mkdir_in);
    if (memchr(name, '\0', name_len) == NULL) { reply_err(in->unique, EINVAL); return; }

    struct inode *parent = inode_get(in->nodeid);
    if (!parent) { reply_err(in->unique, ENOENT); return; }
    if (!parent->is_dir) { reply_err(in->unique, ENOTDIR); return; }
    if (!name_ok(name)) { reply_err(in->unique, EACCES); return; }

    if (mkdirat(parent->path_fd, name, g_cfg.dir_mode & 07777) < 0) {
        reply_err(in->unique, errno);
        return;
    }

    struct inode *child;
    struct stat st;
    int rc = resolve_and_register(parent, name, &child, &st);
    if (rc != 0) { reply_err(in->unique, rc); return; }

    struct fuse_entry_out eo;
    memset(&eo, 0, sizeof(eo));
    eo.nodeid = child->nodeid;
    set_entry_times(&eo);
    fill_fuse_attr(&eo.attr, child, &st);
    reply_ok(in->unique, &eo, sizeof(eo));
}

// remove a name from a directory
static void op_unlink_rmdir(const struct fuse_in_header *in, const uint8_t *body,
                             uint32_t body_len, int is_rmdir) {
    const char *name = (const char *)body;
    if (body_len == 0 || memchr(name, '\0', body_len) == NULL) {
        reply_err(in->unique, EINVAL);
        return;
    }
    struct inode *parent = inode_get(in->nodeid);
    if (!parent) { reply_err(in->unique, ENOENT); return; }
    if (!parent->is_dir) { reply_err(in->unique, ENOTDIR); return; }
    if (!name_ok(name)) { reply_err(in->unique, EACCES); return; }

    if (unlinkat(parent->path_fd, name, is_rmdir ? AT_REMOVEDIR : 0) < 0) {
        reply_err(in->unique, errno);
        return;
    }
    reply_ok(in->unique, NULL, 0);
}

// rename a name between directories with the given flags
static void op_rename_common(const struct fuse_in_header *in, uint64_t newdir,
                              unsigned int flags, const char *oldname, const char *newname) {
    struct inode *old_parent = inode_get(in->nodeid);
    struct inode *new_parent = inode_get(newdir);
    if (!old_parent || !new_parent) { reply_err(in->unique, ENOENT); return; }
    if (!old_parent->is_dir || !new_parent->is_dir) { reply_err(in->unique, ENOTDIR); return; }
    if (!name_ok(oldname) || !name_ok(newname)) { reply_err(in->unique, EACCES); return; }

    if (renameat2(old_parent->path_fd, oldname, new_parent->path_fd, newname, flags) < 0) {
        reply_err(in->unique, errno);
        return;
    }
    reply_ok(in->unique, NULL, 0);
}

// rename an entry
static void op_rename(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len <= sizeof(struct fuse_rename_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_rename_in *ri = (const struct fuse_rename_in *)body;
    const char *oldname = (const char *)(body + sizeof(*ri));
    uint32_t rest_len = body_len - (uint32_t)sizeof(*ri);
    size_t old_len = strnlen(oldname, rest_len);
    if (old_len >= rest_len) { reply_err(in->unique, EINVAL); return; }
    const char *newname = oldname + old_len + 1;
    uint32_t new_budget = rest_len - (uint32_t)old_len - 1;
    if (memchr(newname, '\0', new_budget) == NULL) { reply_err(in->unique, EINVAL); return; }

    op_rename_common(in, ri->newdir, 0, oldname, newname);
}

// rename an entry with flags
static void op_rename2(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len <= sizeof(struct fuse_rename2_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_rename2_in *ri = (const struct fuse_rename2_in *)body;
    const char *oldname = (const char *)(body + sizeof(*ri));
    uint32_t rest_len = body_len - (uint32_t)sizeof(*ri);
    size_t old_len = strnlen(oldname, rest_len);
    if (old_len >= rest_len) { reply_err(in->unique, EINVAL); return; }
    const char *newname = oldname + old_len + 1;
    uint32_t new_budget = rest_len - (uint32_t)old_len - 1;
    if (memchr(newname, '\0', new_budget) == NULL) { reply_err(in->unique, EINVAL); return; }

    op_rename_common(in, ri->newdir, ri->flags, oldname, newname);
}

// reply with the filesystem statistics
static void op_statfs(const struct fuse_in_header *in) {
    struct inode *n = inode_get(in->nodeid);
    if (!n) n = g_root;
    char procpath[64];
    fd_procpath(n->path_fd, procpath, sizeof(procpath));

    struct statfs sfs;
    if (statfs(procpath, &sfs) < 0) { reply_err(in->unique, errno); return; }

    struct fuse_statfs_out out;
    memset(&out, 0, sizeof(out));
    out.st.blocks = (uint64_t)sfs.f_blocks;
    out.st.bfree = (uint64_t)sfs.f_bfree;
    out.st.bavail = (uint64_t)sfs.f_bavail;
    out.st.files = (uint64_t)sfs.f_files;
    out.st.ffree = (uint64_t)sfs.f_ffree;
    out.st.bsize = (uint32_t)sfs.f_bsize;
    out.st.namelen = (uint32_t)sfs.f_namelen;
    out.st.frsize = (uint32_t)sfs.f_frsize;
    reply_ok(in->unique, &out, sizeof(out));
}

// reply success to the access request
static void op_access(const struct fuse_in_header *in) {
    reply_ok(in->unique, NULL, 0);
}

// reply ENOSYS to the xattr request
static void op_xattr_enosys(const struct fuse_in_header *in) {
    reply_err(in->unique, ENOSYS);
}

// open a directory and return its handle
static void op_opendir(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    (void)body;
    if (body_len < sizeof(struct fuse_open_in)) { reply_err(in->unique, EINVAL); return; }
    struct inode *n = inode_get(in->nodeid);
    if (!n) { reply_err(in->unique, ENOENT); return; }
    if (!n->is_dir) { reply_err(in->unique, ENOTDIR); return; }

    int fd = reopen_via_procpath(n->path_fd, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (fd < 0) { reply_err(in->unique, errno); return; }
    DIR *dirp = fdopendir(fd);
    if (!dirp) { int e = errno; close(fd); reply_err(in->unique, e); return; }

    uint64_t fh;
    struct handle *h = handle_alloc(HANDLE_DIR, &fh);
    if (!h) { closedir(dirp); reply_err(in->unique, EMFILE); return; }
    h->dirp = dirp;

    struct fuse_open_out out;
    memset(&out, 0, sizeof(out));
    out.fh = fh;
    reply_ok(in->unique, &out, sizeof(out));
}

// return whether a name is dot or dot-dot
static int is_dot_name(const char *name) {
    return strcmp(name, ".") == 0 || strcmp(name, "..") == 0;
}

// reply with directory entries
static void do_readdir(const struct fuse_in_header *in, const uint8_t *body,
                        uint32_t body_len, int plus) {
    if (body_len < sizeof(struct fuse_read_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_read_in *ri = (const struct fuse_read_in *)body;
    struct handle *h = handle_get(ri->fh, HANDLE_DIR);
    if (!h) { reply_err(in->unique, EBADF); return; }
    DIR *dirp = h->dirp;

    struct inode *dir_inode = inode_get(in->nodeid);
    if (!dir_inode) { reply_err(in->unique, ENOENT); return; }

    if (ri->offset == 0) {
        rewinddir(dirp);
    } else if (!dir_off_issued(h, ri->offset)) {
        reply_err(in->unique, EINVAL);
        return;
    } else {
        seekdir(dirp, (long)ri->offset);
    }
    h->off_count = 0;

    uint32_t want = ri->size;
    if (want > MAX_DIR_BUF) want = MAX_DIR_BUF;
    uint8_t *out = malloc(want ? want : 1);
    if (!out) { reply_err(in->unique, ENOMEM); return; }
    uint32_t used = 0;

    for (;;) {
        if (h->off_count >= DIR_OFF_RING) break;
        long prev_pos = telldir(dirp);
        errno = 0;
        struct dirent *de = readdir(dirp);
        if (!de) break;

        size_t namelen = strlen(de->d_name);
        size_t need = plus
            ? FUSE_REC_ALIGN(offsetof(struct fuse_direntplus, dirent.name) + namelen)
            : FUSE_REC_ALIGN(offsetof(struct fuse_dirent, name) + namelen);

        if (used + need > want) {
            seekdir(dirp, prev_pos);
            break;
        }

        uint64_t entry_off = (uint64_t)telldir(dirp);
        dir_off_record(h, entry_off);

        if (plus) {
            struct fuse_direntplus *dp = (struct fuse_direntplus *)(out + used);
            memset(dp, 0, sizeof(*dp));
            uint64_t report_ino = (uint64_t)de->d_ino;
            if (!is_dot_name(de->d_name)) {
                struct inode *child;
                struct stat st;
                int rc = resolve_and_register(dir_inode, de->d_name, &child, &st);
                if (rc == 0) {
                    dp->entry_out.nodeid = child->nodeid;
                    set_entry_times(&dp->entry_out);
                    fill_fuse_attr(&dp->entry_out.attr, child, &st);
                    report_ino = dp->entry_out.attr.ino;
                }
            }
            dp->dirent.ino = report_ino;
            dp->dirent.off = entry_off;
            dp->dirent.namelen = (uint32_t)namelen;
            dp->dirent.type = de->d_type;
            memcpy(dp->dirent.name, de->d_name, namelen);
        } else {
            struct fuse_dirent *d = (struct fuse_dirent *)(out + used);
            d->ino = (uint64_t)de->d_ino;
            d->off = entry_off;
            d->namelen = (uint32_t)namelen;
            d->type = de->d_type;
            memcpy(d->name, de->d_name, namelen);
        }
        used += (uint32_t)need;
    }

    reply_ok(in->unique, out, used);
    free(out);
}

// drop the directory handle
static void op_releasedir(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len < sizeof(struct fuse_release_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_release_in *rl = (const struct fuse_release_in *)body;
    if (!handle_get(rl->fh, HANDLE_DIR)) { reply_err(in->unique, EBADF); return; }
    handle_put(rl->fh);
    reply_ok(in->unique, NULL, 0);
}

// sync the directory descriptor
static void op_fsyncdir(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len < sizeof(struct fuse_fsync_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_fsync_in *fs = (const struct fuse_fsync_in *)body;
    struct handle *h = handle_get(fs->fh, HANDLE_DIR);
    if (!h) { reply_err(in->unique, EBADF); return; }
    int fd = dirfd(h->dirp);
    int rc = (fs->fsync_flags & FUSE_FSYNC_FDATASYNC) ? fdatasync(fd) : fsync(fd);
    if (rc < 0) { reply_err(in->unique, errno); return; }
    reply_ok(in->unique, NULL, 0);
}


// read or write request
struct io_request {
    uint64_t unique;
    uint64_t fh;
    uint32_t idx;
    int fd;
    int is_write;
    uint64_t offset;
    uint32_t size;
    uint8_t *data;
};

static uint64_t g_st_block_fh = 0;
static pthread_mutex_t g_st_gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_st_gate_cond = PTHREAD_COND_INITIALIZER;
static int g_st_gate_open = 0;

static int g_st_track_order = 0;
static uint64_t g_st_order[4];
static int g_st_order_n = 0;
static pthread_mutex_t g_st_order_lock = PTHREAD_MUTEX_INITIALIZER;

// record a handle number in the selftest order list
static void st_order_record(uint64_t fh) {
    if (!g_st_track_order) return;
    pthread_mutex_lock(&g_st_order_lock);
    if (g_st_order_n < 4) g_st_order[g_st_order_n++] = fh;
    pthread_mutex_unlock(&g_st_order_lock);
}

static pthread_mutex_t g_io_count_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_io_count_cond = PTHREAD_COND_INITIALIZER;
static uint32_t g_io_inflight_threads = 0;

// count an I/O worker thread as started
static void io_thread_begin(void) {
    pthread_mutex_lock(&g_io_count_lock);
    g_io_inflight_threads++;
    pthread_mutex_unlock(&g_io_count_lock);
}

// count an I/O worker thread as finished
static void io_thread_end(void) {
    pthread_mutex_lock(&g_io_count_lock);
    g_io_inflight_threads--;
    if (g_io_inflight_threads == 0) pthread_cond_broadcast(&g_io_count_cond);
    pthread_mutex_unlock(&g_io_count_lock);
}

// wait until no I/O worker thread is running
static void wait_for_io_workers(void) {
    pthread_mutex_lock(&g_io_count_lock);
    while (g_io_inflight_threads > 0) pthread_cond_wait(&g_io_count_cond, &g_io_count_lock);
    pthread_mutex_unlock(&g_io_count_lock);
}

// pin a file handle and return its fd
static int resolve_and_pin_file(uint64_t fh, uint32_t *idx_out, int *fd_out) {
    uint32_t idx = (uint32_t)(fh & 0xffffffffu);
    uint32_t gen = (uint32_t)(fh >> 32);
    pthread_mutex_lock(&g_handle_lock);
    if (idx >= g_handles_used) { pthread_mutex_unlock(&g_handle_lock); return -1; }
    struct handle *h = &g_handles[idx];
    if (h->kind != HANDLE_FILE || h->gen != gen) { pthread_mutex_unlock(&g_handle_lock); return -1; }
    h->inflight++;
    *idx_out = idx;
    *fd_out = h->fd;
    pthread_mutex_unlock(&g_handle_lock);
    return 0;
}

// unpin a handle and finish a deferred close
static void io_worker_pin_release(uint32_t idx) {
    pthread_mutex_lock(&g_handle_lock);
    struct handle *h = &g_handles[idx];
    h->inflight--;
    if (h->inflight == 0 && h->closing) {
        if (h->fd >= 0) close(h->fd);
        free(h->offs);
        h->kind = HANDLE_FREE;
        h->fd = -1;
        h->dirp = NULL;
        h->offs = NULL;
        h->off_count = 0;
        h->closing = 0;
        h->next_free = g_handle_free;
        g_handle_free = (int32_t)idx;
    }
    pthread_mutex_unlock(&g_handle_lock);
}

// read or write a file and reply
static void *io_worker(void *argp) {
    struct io_request *req = argp;

    if (g_st_block_fh && req->fh == g_st_block_fh) {
        pthread_mutex_lock(&g_st_gate_lock);
        while (!g_st_gate_open) pthread_cond_wait(&g_st_gate_cond, &g_st_gate_lock);
        pthread_mutex_unlock(&g_st_gate_lock);
    }

    if (req->is_write) {
        size_t total = 0;
        int err = 0;
        while (total < req->size) {
            ssize_t w = pwrite(req->fd, req->data + total, req->size - total, (off_t)(req->offset + total));
            if (w < 0) {
                if (errno == EINTR) continue;
                if (total > 0) break;
                err = errno;
                break;
            }
            if (w == 0) break;
            total += (size_t)w;
        }
        if (total == 0 && err != 0) {
            reply_err(req->unique, err);
        } else {
            struct fuse_write_out out;
            memset(&out, 0, sizeof(out));
            out.size = (uint32_t)total;
            reply_ok(req->unique, &out, sizeof(out));
        }
        free(req->data);
    } else {
        uint8_t *buf = malloc(req->size ? req->size : 1);
        if (!buf) {
            reply_err(req->unique, ENOMEM);
        } else {
            size_t total = 0;
            int err = 0;
            while (total < req->size) {
                ssize_t r = pread(req->fd, buf + total, req->size - total, (off_t)(req->offset + total));
                if (r < 0) {
                    if (errno == EINTR) continue;
                    err = errno;
                    break;
                }
                if (r == 0) break;
                total += (size_t)r;
            }
            if (err != 0) {
                reply_err(req->unique, err);
            } else {
                reply_ok(req->unique, buf, (uint32_t)total);
            }
            free(buf);
        }
    }

    st_order_record(req->fh);
    io_worker_pin_release(req->idx);
    free(req);
    io_thread_end();
    return NULL;
}

// start a detached thread for the request
static int spawn_io_worker(struct io_request *req) {
    io_thread_begin();
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t tid;
    int rc = pthread_create(&tid, &attr, io_worker, req);
    pthread_attr_destroy(&attr);
    if (rc != 0) { io_thread_end(); return -1; }
    return 0;
}

// read the file into the reply
static void op_read(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len < sizeof(struct fuse_read_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_read_in *ri = (const struct fuse_read_in *)body;

    uint32_t size = ri->size;
    if (size > MAX_WRITE_SIZE) size = MAX_WRITE_SIZE;

    struct io_request *req = malloc(sizeof(*req));
    if (!req) { reply_err(in->unique, ENOMEM); return; }

    uint32_t idx; int fd;
    if (resolve_and_pin_file(ri->fh, &idx, &fd) != 0) {
        free(req);
        reply_err(in->unique, EBADF);
        return;
    }
    req->unique = in->unique;
    req->fh = ri->fh;
    req->idx = idx;
    req->fd = fd;
    req->is_write = 0;
    req->offset = ri->offset;
    req->size = size;
    req->data = NULL;

    if (spawn_io_worker(req) != 0) {
        io_worker_pin_release(idx);
        free(req);
        reply_err(in->unique, EAGAIN);
    }
}

// write data to a file
static void op_write(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len < sizeof(struct fuse_write_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_write_in *wi = (const struct fuse_write_in *)body;
    const uint8_t *data = body + sizeof(*wi);
    uint32_t avail = body_len - (uint32_t)sizeof(*wi);
    uint32_t size = wi->size < avail ? wi->size : avail;

    struct io_request *req = malloc(sizeof(*req));
    if (!req) { reply_err(in->unique, ENOMEM); return; }
    req->data = malloc(size ? size : 1);
    if (!req->data) { free(req); reply_err(in->unique, ENOMEM); return; }
    memcpy(req->data, data, size);

    uint32_t idx; int fd;
    if (resolve_and_pin_file(wi->fh, &idx, &fd) != 0) {
        free(req->data);
        free(req);
        reply_err(in->unique, EBADF);
        return;
    }
    req->unique = in->unique;
    req->fh = wi->fh;
    req->idx = idx;
    req->fd = fd;
    req->is_write = 1;
    req->offset = wi->offset;
    req->size = size;

    if (spawn_io_worker(req) != 0) {
        io_worker_pin_release(idx);
        free(req->data);
        free(req);
        reply_err(in->unique, EAGAIN);
    }
}

// release a file handle
static void op_release(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len < sizeof(struct fuse_release_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_release_in *rl = (const struct fuse_release_in *)body;
    if (!handle_get(rl->fh, HANDLE_FILE)) { reply_err(in->unique, EBADF); return; }

    uint32_t idx = (uint32_t)(rl->fh & 0xffffffffu);
    int defer;
    pthread_mutex_lock(&g_handle_lock);
    struct handle *h = &g_handles[idx];
    defer = (h->inflight > 0);
    if (defer) h->closing = 1;
    pthread_mutex_unlock(&g_handle_lock);

    if (!defer) handle_put(rl->fh);
    reply_ok(in->unique, NULL, 0);
}

// reply success to the flush request
static void op_flush(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    (void)body;
    (void)body_len;
    reply_ok(in->unique, NULL, 0);
}

// sync the file descriptor
static void op_fsync(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    if (body_len < sizeof(struct fuse_fsync_in)) { reply_err(in->unique, EINVAL); return; }
    const struct fuse_fsync_in *fs = (const struct fuse_fsync_in *)body;
    struct handle *h = handle_get(fs->fh, HANDLE_FILE);
    if (!h) { reply_err(in->unique, EBADF); return; }
    int fd = h->fd;
    int rc = (fs->fsync_flags & FUSE_FSYNC_FDATASYNC) ? fdatasync(fd) : fsync(fd);
    if (rc < 0) { reply_err(in->unique, errno); return; }
    reply_ok(in->unique, NULL, 0);
}

// ignore the interrupt request
static void op_interrupt(const struct fuse_in_header *in) {
    (void)in;
}


// call the operation for the opcode
static void dispatch(const struct fuse_in_header *in, const uint8_t *body, uint32_t body_len) {
    switch (in->opcode) {
        case FUSE_INIT: op_init(in, body, body_len); break;
        case FUSE_DESTROY: op_destroy(in); break;
        case FUSE_LOOKUP: op_lookup(in, body, body_len); break;
        case FUSE_FORGET: op_forget(in, body, body_len); break;
        case FUSE_BATCH_FORGET: op_batch_forget(in, body, body_len); break;
        case FUSE_GETATTR: op_getattr(in); break;
        case FUSE_SETATTR: op_setattr(in, body, body_len); break;
        case FUSE_OPEN: op_open(in, body, body_len); break;
        case FUSE_READ: op_read(in, body, body_len); break;
        case FUSE_WRITE: op_write(in, body, body_len); break;
        case FUSE_RELEASE: op_release(in, body, body_len); break;
        case FUSE_FLUSH: op_flush(in, body, body_len); break;
        case FUSE_FSYNC: op_fsync(in, body, body_len); break;
        case FUSE_OPENDIR: op_opendir(in, body, body_len); break;
        case FUSE_READDIR: do_readdir(in, body, body_len, 0); break;
        case FUSE_READDIRPLUS: do_readdir(in, body, body_len, 1); break;
        case FUSE_RELEASEDIR: op_releasedir(in, body, body_len); break;
        case FUSE_FSYNCDIR: op_fsyncdir(in, body, body_len); break;
        case FUSE_CREATE: op_create(in, body, body_len); break;
        case FUSE_MKDIR: op_mkdir(in, body, body_len); break;
        case FUSE_UNLINK: op_unlink_rmdir(in, body, body_len, 0); break;
        case FUSE_RMDIR: op_unlink_rmdir(in, body, body_len, 1); break;
        case FUSE_RENAME: op_rename(in, body, body_len); break;
        case FUSE_RENAME2: op_rename2(in, body, body_len); break;
        case FUSE_STATFS: op_statfs(in); break;
        case FUSE_ACCESS: op_access(in); break;
        case FUSE_GETXATTR: op_xattr_enosys(in); break;
        case FUSE_SETXATTR: op_xattr_enosys(in); break;
        case FUSE_LISTXATTR: op_xattr_enosys(in); break;
        case FUSE_REMOVEXATTR: op_xattr_enosys(in); break;
        case FUSE_INTERRUPT: op_interrupt(in); break;
        default:
            reply_err(in->unique, ENOSYS);
            break;
    }
}


#if defined(__x86_64__)
#define RHIZO_SECCOMP_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define RHIZO_SECCOMP_ARCH AUDIT_ARCH_AARCH64
#define SYS_poll SYS_ppoll
#define SYS_chmod SYS_fchmodat
#else
#error "rhizo-hostfsd: no seccomp syscall set for this architecture"
#endif

#define X32_BIT 0x40000000u

static const int g_seccomp_allow[] = {
    SYS_read, SYS_write, SYS_writev, SYS_poll, SYS_ppoll,

    SYS_openat, SYS_close, SYS_pread64, SYS_pwrite64, SYS_lseek,
    SYS_getdents64, SYS_fcntl,

    SYS_fstat, SYS_newfstatat, SYS_statx, SYS_statfs, SYS_fstatfs,

    SYS_ftruncate, SYS_chmod, SYS_fchmodat, SYS_utimensat,

    SYS_fsync, SYS_fdatasync,

    SYS_mkdirat, SYS_unlinkat, SYS_renameat, SYS_renameat2,

    SYS_brk, SYS_mmap, SYS_munmap, SYS_mremap, SYS_madvise, SYS_futex,
    SYS_getrandom, SYS_clock_gettime,

    SYS_rt_sigreturn, SYS_restart_syscall, SYS_exit, SYS_exit_group,

    SYS_clone3, SYS_clone, SYS_mprotect, SYS_set_robust_list, SYS_rseq,
    SYS_rt_sigaction, SYS_rt_sigprocmask,
};

// read the seccomp mode from /proc/self/status
static int seccomp_mode(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    int mode = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "Seccomp:", 8) == 0) { mode = atoi(line + 8); break; }
    }
    fclose(f);
    return mode;
}

// install the seccomp syscall filter
static int seccomp_install(void) {
    size_t n_allow = sizeof(g_seccomp_allow) / sizeof(g_seccomp_allow[0]);
    size_t n = 0, cap = 2 * n_allow + 8;
    struct sock_filter *f = calloc(cap, sizeof(*f));
    if (!f) { logf_err("seccomp: out of memory building the filter"); return -1; }

    f[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
    f[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, RHIZO_SECCOMP_ARCH, 1, 0);
    f[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
    f[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
    f[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, X32_BIT, 0, 1);
    f[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
    for (size_t i = 0; i < n_allow; i++) {
        f[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                              (unsigned)g_seccomp_allow[i], 0, 1);
        f[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    }
    f[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);

    struct sock_fprog prog = { .len = (unsigned short)n, .filter = f };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        logf_err("seccomp: PR_SET_NO_NEW_PRIVS failed: %s", strerror(errno));
        free(f);
        return -1;
    }
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0) != 0) {
        logf_err("seccomp: PR_SET_SECCOMP failed: %s", strerror(errno));
        free(f);
        return -1;
    }
    free(f);

    int mode = seccomp_mode();
    if (mode != 2) {
        logf_err("seccomp: filter did not attach (Seccomp: %d in /proc/self/status, want 2)", mode);
        return -1;
    }
    rz_log("seccomp: filter attached, %zu syscalls allowed in %zu BPF instructions", n_allow, n);
    return 0;
}


// read and dispatch FUSE requests
static void serve_forever(void) {
    for (;;) {
        ssize_t n;
        do {
            n = read(g_fuse_fd, g_inbuf, sizeof(g_inbuf));
        } while (n < 0 && errno == EINTR);

        if (n < 0) {
            if (errno == ENODEV) {
                rz_log("device unmounted (ENODEV), exiting cleanly");
                break;
            }
            if (errno == EAGAIN) continue;
            logf_err("read(/dev/fuse) failed: %s", strerror(errno));
            break;
        }
        if (n == 0) {
            rz_log("read(/dev/fuse) returned EOF, exiting");
            break;
        }
        if ((size_t)n < sizeof(struct fuse_in_header)) {
            logf_err("short read from /dev/fuse: %zd bytes (need at least %zu)",
                      n, sizeof(struct fuse_in_header));
            continue;
        }

        const struct fuse_in_header *in = (const struct fuse_in_header *)g_inbuf;
        if (in->len > (uint32_t)n) {
            logf_err("truncated request unique=%" PRIu64 " opcode=%u: header says %u bytes, got %zd",
                      in->unique, in->opcode, in->len, n);
            continue;
        }
        if (in->len < sizeof(struct fuse_in_header)) {
            logf_err("malformed request unique=%" PRIu64 ": len=%u smaller than header",
                      in->unique, in->len);
            continue;
        }

        const uint8_t *body = g_inbuf + sizeof(struct fuse_in_header);
        uint32_t body_len = in->len - (uint32_t)sizeof(struct fuse_in_header);

        dispatch(in, body, body_len);

        if (g_destroy_requested) break;
    }
}


#include <sys/wait.h>

static int g_selftest_failures = 0;

#define SELFTEST_CHECK(cond, msg) \
    do { \
        if (!(cond)) { \
            fprintf(stderr, "SELFTEST FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
            g_selftest_failures++; \
        } else { \
            fprintf(stderr, "SELFTEST OK:   %s\n", msg); \
        } \
    } while (0)

// write a file with the given content for the selftest
static void write_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { fprintf(stderr, "selftest setup: open(%s) failed: %s\n", path, strerror(errno)); exit(1); }
    size_t len = strlen(content);
    if (write(fd, content, len) != (ssize_t)len) { fprintf(stderr, "selftest setup: write(%s) failed\n", path); exit(1); }
    close(fd);
}


#include <ftw.h>

static int g_st_replyfd = -1;
static uint64_t g_st_unique = 0;
static uint8_t *g_st_req = NULL;
static uint8_t *g_st_reply = NULL;
static uint32_t g_st_reply_len = 0;
static int32_t g_st_reply_error = 0;
static uint32_t g_st_uid = 0, g_st_gid = 0, g_st_pid = 0;

// print a selftest setup failure and exit
static void st_fatal(const char *what) {
    fprintf(stderr, "selftest setup: %s failed: %s\n", what, strerror(errno));
    _exit(1);
}

// remove a path of a tree
static int st_rm_one(const char *path, const struct stat *st, int flag, struct FTW *ftw) {
    (void)st; (void)flag; (void)ftw;
    remove(path);
    return 0;
}

// remove a tree
static void st_rm_rf(const char *path) {
    nftw(path, st_rm_one, 16, FTW_DEPTH | FTW_PHYS);
}

// create the scratch directory and reply file
static char *st_setup(char *tmpl) {
    char *scratch = mkdtemp(tmpl);
    if (!scratch) st_fatal("mkdtemp");
    g_st_uid = getuid();
    g_st_gid = getgid();
    g_st_pid = (uint32_t)getpid();
    g_st_req = malloc(IN_BUF_SIZE);
    g_st_reply = malloc(IN_BUF_SIZE);
    if (!g_st_req || !g_st_reply) st_fatal("malloc");
    char reply_tmpl[] = "/tmp/rhizo-hostfsd-selftest-reply-XXXXXX";
    g_st_replyfd = mkstemp(reply_tmpl);
    if (g_st_replyfd < 0) st_fatal("mkstemp");
    unlink(reply_tmpl);
    g_fuse_fd = g_st_replyfd;
    return scratch;
}

// build a request and dispatch it
static uint64_t st_send(uint32_t opcode, uint64_t nodeid, const void *body, size_t body_len) {
    if (sizeof(struct fuse_in_header) + body_len > IN_BUF_SIZE) st_fatal("request larger than the read buffer");
    struct fuse_in_header *ih = (struct fuse_in_header *)g_st_req;
    memset(ih, 0, sizeof(*ih));
    ih->len = (uint32_t)(sizeof(*ih) + body_len);
    ih->opcode = opcode;
    ih->unique = ++g_st_unique;
    ih->nodeid = nodeid;
    ih->uid = g_st_uid;
    ih->gid = g_st_gid;
    ih->pid = g_st_pid;
    if (body_len) memcpy(g_st_req + sizeof(*ih), body, body_len);
    dispatch(ih, g_st_req + sizeof(*ih), (uint32_t)body_len);
    return ih->unique;
}

// send a request and read its reply
static void st_call(uint32_t opcode, uint64_t nodeid, const void *body, size_t body_len) {
    if (ftruncate(g_st_replyfd, 0) != 0 || lseek(g_st_replyfd, 0, SEEK_SET) != 0) st_fatal("reply file reset");
    g_st_reply_len = 0;
    g_st_reply_error = 0;

    uint64_t unique = st_send(opcode, nodeid, body, body_len);
    wait_for_io_workers();

    off_t end = lseek(g_st_replyfd, 0, SEEK_END);
    if (end < 0) st_fatal("reply file seek");
    if (end == 0) return;
    if (lseek(g_st_replyfd, 0, SEEK_SET) != 0) st_fatal("reply file rewind");
    ssize_t got = read(g_st_replyfd, g_st_reply, IN_BUF_SIZE);
    if (got < (ssize_t)sizeof(struct fuse_out_header)) st_fatal("reply shorter than its own header");
    const struct fuse_out_header *oh = (const struct fuse_out_header *)g_st_reply;
    g_st_reply_error = oh->error;
    g_st_reply_len = (uint32_t)got - (uint32_t)sizeof(*oh);
    if (oh->len != (uint32_t)got) {
        fprintf(stderr, "SELFTEST FAIL: reply header claims %u bytes, %zd landed on the fd\n", oh->len, got);
        g_selftest_failures++;
    }
    if (oh->unique != unique) {
        fprintf(stderr, "SELFTEST FAIL: reply unique=%" PRIu64 " does not answer request %" PRIu64 "\n",
                oh->unique, unique);
        g_selftest_failures++;
    }
}

// return the error number of the last selftest reply
static int st_errno(void) { return g_st_reply_error < 0 ? -g_st_reply_error : 0; }
// return the body of the last selftest reply
static const void *st_body(void) { return g_st_reply + sizeof(struct fuse_out_header); }

// send a LOOKUP request in the selftest
static void st_lookup(uint64_t parent, const char *name) {
    st_call(FUSE_LOOKUP, parent, name, strlen(name) + 1);
}

// send a FORGET request in the selftest
static void st_forget(uint64_t nodeid, uint64_t nlookup) {
    struct fuse_forget_in fi;
    memset(&fi, 0, sizeof(fi));
    fi.nlookup = nlookup;
    st_call(FUSE_FORGET, nodeid, &fi, sizeof(fi));
}

// send a CREATE request in the selftest
static void st_create(uint64_t parent, const char *name, uint32_t flags) {
    uint8_t buf[sizeof(struct fuse_create_in) + NAME_MAX_LEN + 2];
    size_t n = strlen(name) + 1;
    if (n > NAME_MAX_LEN + 1) st_fatal("selftest name too long");
    struct fuse_create_in ci;
    memset(&ci, 0, sizeof(ci));
    ci.flags = flags;
    ci.mode = S_IFREG | 0644;
    memcpy(buf, &ci, sizeof(ci));
    memcpy(buf + sizeof(ci), name, n);
    st_call(FUSE_CREATE, parent, buf, sizeof(ci) + n);
}

// send an open request in the selftest
static void st_open(uint32_t opcode, uint64_t nodeid, uint32_t flags, size_t body_len) {
    struct fuse_open_in oi;
    memset(&oi, 0, sizeof(oi));
    oi.flags = flags;
    st_call(opcode, nodeid, &oi, body_len);
}

// send a read request in the selftest
static void st_read(uint32_t opcode, uint64_t nodeid, uint64_t fh, uint64_t offset, uint32_t size) {
    struct fuse_read_in ri;
    memset(&ri, 0, sizeof(ri));
    ri.fh = fh;
    ri.offset = offset;
    ri.size = size;
    st_call(opcode, nodeid, &ri, sizeof(ri));
}

// send a WRITE request in the selftest
static void st_write(uint64_t nodeid, uint64_t fh, uint64_t offset, const char *data, uint32_t len) {
    uint8_t buf[sizeof(struct fuse_write_in) + 128];
    if (len > 128) st_fatal("selftest write too long");
    struct fuse_write_in wi;
    memset(&wi, 0, sizeof(wi));
    wi.fh = fh;
    wi.offset = offset;
    wi.size = len;
    memcpy(buf, &wi, sizeof(wi));
    memcpy(buf + sizeof(wi), data, len);
    st_call(FUSE_WRITE, nodeid, buf, sizeof(wi) + len);
}

// send a release request in the selftest
static void st_release(uint32_t opcode, uint64_t nodeid, uint64_t fh) {
    struct fuse_release_in rl;
    memset(&rl, 0, sizeof(rl));
    rl.fh = fh;
    st_call(opcode, nodeid, &rl, sizeof(rl));
}

// send an fsync request in the selftest
static void st_fsync(uint32_t opcode, uint64_t nodeid, uint64_t fh) {
    struct fuse_fsync_in fs;
    memset(&fs, 0, sizeof(fs));
    fs.fh = fh;
    st_call(opcode, nodeid, &fs, sizeof(fs));
}

// read NoNewPrivs from /proc/self/status
static int st_no_new_privs(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    int value = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "NoNewPrivs:", 11) == 0) { value = atoi(line + 11); break; }
    }
    fclose(f);
    return value;
}

// read a whole file into a buffer for the selftest
static size_t st_slurp(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return (size_t)-1;
    ssize_t n = read(fd, buf, cap);
    close(fd);
    return n < 0 ? (size_t)-1 : (size_t)n;
}

// run a test group in a child process
static void st_group(const char *label, void (*fn)(void)) {
    fflush(NULL);
    pid_t pid = fork();
    if (pid < 0) { SELFTEST_CHECK(0, "fork a dispatch-selftest group"); return; }
    if (pid == 0) {
        alarm(20);
        g_selftest_failures = 0;
        fn();
        fflush(NULL);
        _exit(g_selftest_failures > 100 ? 100 : g_selftest_failures);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
    if (WIFSIGNALED(status)) {
        fprintf(stderr, "SELFTEST FAIL: dispatch group '%s' died on signal %d\n", label, WTERMSIG(status));
        g_selftest_failures++;
    } else if (!WIFEXITED(status)) {
        fprintf(stderr, "SELFTEST FAIL: dispatch group '%s' did not exit normally\n", label);
        g_selftest_failures++;
    } else {
        g_selftest_failures += WEXITSTATUS(status);
    }
}

// test CREATE onto symlinks and free names
static void st_group_create(void) {
    char tmpl[] = "/tmp/rhizo-hostfsd-selftest-create-XXXXXX";
    char *scratch = st_setup(tmpl);
    char root[96], outside[96], secret[160], stolen[160], path[160];
    snprintf(root, sizeof(root), "%s/root", scratch);
    snprintf(outside, sizeof(outside), "%s/outside", scratch);
    if (mkdir(root, 0755) != 0 || mkdir(outside, 0755) != 0) st_fatal("mkdir");
    snprintf(secret, sizeof(secret), "%s/secret.txt", outside);
    write_file(secret, "SECRET-CONTENT-THE-SHARE-MUST-NEVER-REACH");
    snprintf(stolen, sizeof(stolen), "%s/created-by-symlink.txt", outside);

    snprintf(path, sizeof(path), "%s/onto_secret", root);
    if (symlink("../outside/secret.txt", path) != 0) st_fatal("symlink");
    char link_path[160];
    snprintf(link_path, sizeof(link_path), "%s/onto_new", root);
    if (symlink("../outside/created-by-symlink.txt", link_path) != 0) st_fatal("symlink");

    g_cfg.uid = 1023;
    g_cfg.gid = 1023;
    g_cfg.file_mode = 0664;
    g_cfg.dir_mode = 0775;
    inode_table_init(root);

    struct stat before, after;
    if (stat(secret, &before) != 0) st_fatal("stat the outside file");

    st_create(FUSE_ROOT_ID, "onto_secret", O_WRONLY | O_CREAT | O_TRUNC);
    SELFTEST_CHECK(st_errno() != 0, "dispatch: CREATE onto a symlinked name is refused");
    SELFTEST_CHECK(stat(secret, &after) == 0 && after.st_size == before.st_size,
                   "dispatch: a refused CREATE did not truncate the symlink's target outside the share");
    SELFTEST_CHECK(lstat(path, &after) == 0 && S_ISLNK(after.st_mode),
                   "dispatch: a refused CREATE left the symlink itself in place");

    st_create(FUSE_ROOT_ID, "onto_new", O_WRONLY | O_CREAT);
    SELFTEST_CHECK(st_errno() != 0, "dispatch: CREATE onto a dangling symlink is refused");
    SELFTEST_CHECK(access(stolen, F_OK) != 0,
                   "dispatch: a refused CREATE did not create the symlink's target outside the share");

    st_create(FUSE_ROOT_ID, "made.txt", O_WRONLY | O_CREAT | O_EXCL);
    int made_ok = (st_errno() == 0 &&
                   g_st_reply_len == sizeof(struct fuse_entry_out) + sizeof(struct fuse_open_out));
    SELFTEST_CHECK(made_ok, "dispatch: CREATE of a free name succeeds and answers entry+open");
    if (made_ok) {
        const struct fuse_entry_out *eo = st_body();
        const struct fuse_open_out *oo =
            (const struct fuse_open_out *)((const uint8_t *)st_body() + sizeof(*eo));
        uint64_t nodeid = eo->nodeid;
        uint64_t fh = oo->fh;
        SELFTEST_CHECK(nodeid > FUSE_ROOT_ID, "dispatch: a created file is registered under a new nodeid");
        SELFTEST_CHECK(eo->attr.uid == g_cfg.uid && (eo->attr.mode & 07777) == g_cfg.file_mode,
                       "dispatch: a created file reports the configured uid and file-mode");
        st_write(nodeid, fh, 0, "landed", 6);
        SELFTEST_CHECK(st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_write_out) &&
                           ((const struct fuse_write_out *)st_body())->size == 6,
                       "dispatch: WRITE through a CREATE handle acknowledges every byte");
        st_release(FUSE_RELEASE, nodeid, fh);
        SELFTEST_CHECK(st_errno() == 0, "dispatch: RELEASE of a CREATE handle succeeds");
        char got[16];
        snprintf(path, sizeof(path), "%s/made.txt", root);
        size_t n = st_slurp(path, got, sizeof(got));
        SELFTEST_CHECK(n == 6 && memcmp(got, "landed", 6) == 0,
                       "dispatch: the bytes written through a CREATE handle are on disk under --root");
    }

    st_create(FUSE_ROOT_ID, "a/b", O_WRONLY | O_CREAT);
    SELFTEST_CHECK(st_errno() == EACCES, "dispatch: CREATE of a name containing '/' is refused");
    st_create(FUSE_ROOT_ID, "..", O_WRONLY | O_CREAT);
    SELFTEST_CHECK(st_errno() == EACCES, "dispatch: CREATE of \"..\" is refused");

    st_rm_rf(scratch);
}

// collect names from the reply directory entries
static int st_dirents(char names[][NAME_MAX_LEN + 1], int cap, uint64_t *last_off) {
    const uint8_t *p = st_body();
    uint32_t off = 0;
    int n = 0;
    while (off + offsetof(struct fuse_dirent, name) <= g_st_reply_len) {
        const struct fuse_dirent *d = (const struct fuse_dirent *)(p + off);
        if (d->namelen > NAME_MAX_LEN) break;
        size_t rec = FUSE_REC_ALIGN(offsetof(struct fuse_dirent, name) + d->namelen);
        if (off + rec > g_st_reply_len) break;
        if (n < cap) {
            memcpy(names[n], d->name, d->namelen);
            names[n][d->namelen] = '\0';
        }
        if (last_off) *last_off = d->off;
        n++;
        off += (uint32_t)rec;
    }
    return n;
}

static uint64_t g_st_case_fh = 0;
static uint64_t g_st_case_dh = 0;

// check that a file handle used as a directory handle is refused
static void st_case_file_fh_as_dir(void) {
    st_read(FUSE_READDIR, FUSE_ROOT_ID, g_st_case_fh, 0, 4096);
    SELFTEST_CHECK(st_errno() == EBADF, "dispatch: a file handle used as a directory handle is refused");
}

// check that FSYNCDIR with handle 0 is refused
static void st_case_fsyncdir_zero_fh(void) {
    st_fsync(FUSE_FSYNCDIR, FUSE_ROOT_ID, 0);
    SELFTEST_CHECK(st_errno() == EBADF, "dispatch: FSYNCDIR with fh=0 is refused, not dereferenced");
}

// check that a released directory handle is refused
static void st_case_released_dir_fh(void) {
    st_read(FUSE_READDIR, FUSE_ROOT_ID, g_st_case_dh, 0, 4096);
    SELFTEST_CHECK(st_errno() == EBADF, "dispatch: a released directory handle is refused");
}

#define ST_SECRET "SECRET-BYTES-NO-APP-MAY-EVER-SEE"

// test file and directory handle requests
static void st_group_handles(void) {
    char tmpl[] = "/tmp/rhizo-hostfsd-selftest-handles-XXXXXX";
    char *scratch = st_setup(tmpl);
    char root[96], outside[96], secret[160], path[160];
    snprintf(root, sizeof(root), "%s/root", scratch);
    snprintf(outside, sizeof(outside), "%s/outside", scratch);
    if (mkdir(root, 0755) != 0 || mkdir(outside, 0755) != 0) st_fatal("mkdir");
    snprintf(secret, sizeof(secret), "%s/secret.txt", outside);
    write_file(secret, ST_SECRET);
    snprintf(path, sizeof(path), "%s/hello.txt", root);
    write_file(path, "hello world");
    snprintf(path, sizeof(path), "%s/second.txt", root);
    write_file(path, "second");
    snprintf(path, sizeof(path), "%s/sub", root);
    if (mkdir(path, 0755) != 0) st_fatal("mkdir sub");

    inode_table_init(root);

    uint64_t hello = 0;
    st_lookup(FUSE_ROOT_ID, "hello.txt");
    if (st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_entry_out))
        hello = ((const struct fuse_entry_out *)st_body())->nodeid;
    SELFTEST_CHECK(hello > FUSE_ROOT_ID, "dispatch: LOOKUP of a real file answers a nodeid");

    uint64_t fh = 0;
    st_open(FUSE_OPEN, hello, O_RDONLY, sizeof(struct fuse_open_in));
    if (st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_open_out))
        fh = ((const struct fuse_open_out *)st_body())->fh;
    SELFTEST_CHECK(st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_open_out),
                   "dispatch: OPEN of a real file answers a handle");
    st_read(FUSE_READ, hello, fh, 0, 64);
    SELFTEST_CHECK(st_errno() == 0 && g_st_reply_len == 11 && memcmp(st_body(), "hello world", 11) == 0,
                   "dispatch: READ through an issued handle returns the file's real bytes");

    int secret_fd = open(secret, O_RDWR);
    if (secret_fd < 0) st_fatal("open the outside file");

    st_read(FUSE_READ, hello, (uint64_t)secret_fd, 0, 64);
    SELFTEST_CHECK(st_errno() == EBADF,
                   "dispatch: a forged fh naming a descriptor the daemon holds for itself is refused by READ");
    SELFTEST_CHECK(!(st_errno() == 0 && g_st_reply_len >= strlen(ST_SECRET) &&
                     memcmp(st_body(), ST_SECRET, strlen(ST_SECRET)) == 0),
                   "dispatch: a forged fh did not read back a file outside the share");

    st_write(hello, (uint64_t)secret_fd, 0, "PWNED", 5);
    SELFTEST_CHECK(st_errno() == EBADF, "dispatch: a forged fh is refused by WRITE");
    char got[80];
    size_t n = st_slurp(secret, got, sizeof(got));
    SELFTEST_CHECK(n == strlen(ST_SECRET) && memcmp(got, ST_SECRET, n) == 0,
                   "dispatch: a forged fh did not overwrite a file outside the share");

    st_release(FUSE_RELEASE, hello, (uint64_t)secret_fd);
    SELFTEST_CHECK(fcntl(secret_fd, F_GETFD) >= 0,
                   "dispatch: a forged fh did not close a descriptor the daemon holds for itself");

    st_release(FUSE_RELEASE, hello, fh);
    SELFTEST_CHECK(st_errno() == 0, "dispatch: RELEASE of an issued handle succeeds");
    close(secret_fd);
    char secret2[160];
    snprintf(secret2, sizeof(secret2), "%s/secret2.txt", outside);
    write_file(secret2, ST_SECRET);
    int reclaimed = open(secret2, O_RDONLY);
    st_read(FUSE_READ, hello, fh, 0, 64);
    SELFTEST_CHECK(st_errno() == EBADF,
                   "dispatch: a released fh is refused, not replayed against whatever took its number");
    SELFTEST_CHECK(!(st_errno() == 0 && g_st_reply_len >= strlen(ST_SECRET) &&
                     memcmp(st_body(), ST_SECRET, strlen(ST_SECRET)) == 0),
                   "dispatch: a released fh did not read back the file that took its number");
    if (reclaimed >= 0) close(reclaimed);

    uint64_t dh = 0;
    st_open(FUSE_OPENDIR, FUSE_ROOT_ID, O_RDONLY, sizeof(struct fuse_open_in));
    if (st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_open_out))
        dh = ((const struct fuse_open_out *)st_body())->fh;
    SELFTEST_CHECK(st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_open_out),
                   "dispatch: OPENDIR answers a handle");

    char names[16][NAME_MAX_LEN + 1];
    st_read(FUSE_READDIR, FUSE_ROOT_ID, dh, 0, 4096);
    int listed = st_dirents(names, 16, NULL);
    SELFTEST_CHECK(st_errno() == 0 && listed == 5,
                   "dispatch: READDIR lists every entry of the root in one buffer");

    uint64_t off = 0;
    int total = 0, rounds = 0, hello_seen = 0, refused = 0;
    for (rounds = 0; rounds < 64; rounds++) {
        st_read(FUSE_READDIR, FUSE_ROOT_ID, dh, off, 96);
        if (st_errno() != 0) { refused = 1; break; }
        int got_n = st_dirents(names, 16, &off);
        if (got_n == 0) break;
        for (int i = 0; i < got_n && i < 16; i++)
            if (strcmp(names[i], "hello.txt") == 0) hello_seen++;
        total += got_n;
    }
    SELFTEST_CHECK(!refused && rounds > 1 && rounds < 64 && total == 5 && hello_seen == 1,
                   "dispatch: a READDIR resumed on its own last offset lists the directory exactly once");

    st_read(FUSE_READDIR, FUSE_ROOT_ID, dh, 0x5eed5eed5eedULL, 4096);
    SELFTEST_CHECK(st_errno() == EINVAL,
                   "dispatch: a READDIR offset this daemon never issued is refused, not fed to seekdir");

    st_read(FUSE_READDIR, FUSE_ROOT_ID, dh, 0, 4096);
    SELFTEST_CHECK(st_errno() == 0 && st_dirents(names, 16, NULL) == 5,
                   "dispatch: READDIR at offset 0 rewinds and lists the directory again");

    g_st_case_fh = fh;
    st_open(FUSE_OPEN, hello, O_RDONLY, sizeof(struct fuse_open_in));
    if (st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_open_out))
        g_st_case_fh = ((const struct fuse_open_out *)st_body())->fh;
    st_group("file handle as a directory handle", st_case_file_fh_as_dir);
    st_group("FSYNCDIR with fh=0", st_case_fsyncdir_zero_fh);

    st_fsync(FUSE_FSYNC, hello, g_st_case_fh);
    SELFTEST_CHECK(st_errno() == 0, "dispatch: FSYNC through an issued file handle succeeds");
    st_release(FUSE_RELEASE, hello, g_st_case_fh);
    SELFTEST_CHECK(st_errno() == 0, "dispatch: RELEASE of that file handle succeeds");

    st_fsync(FUSE_FSYNCDIR, FUSE_ROOT_ID, dh);
    SELFTEST_CHECK(st_errno() == 0, "dispatch: FSYNCDIR through an issued directory handle succeeds");
    st_release(FUSE_RELEASEDIR, FUSE_ROOT_ID, dh);
    SELFTEST_CHECK(st_errno() == 0, "dispatch: RELEASEDIR of an issued handle succeeds");
    g_st_case_dh = dh;
    st_group("released directory handle", st_case_released_dir_fh);

    st_rm_rf(scratch);
}

// return the number of directory entries in the last reply
static int st_direntplus_count(void) {
    const uint8_t *p = st_body();
    uint32_t off = 0;
    int n = 0;
    while (off + offsetof(struct fuse_direntplus, dirent.name) <= g_st_reply_len) {
        const struct fuse_direntplus *d = (const struct fuse_direntplus *)(p + off);
        if (d->dirent.namelen > NAME_MAX_LEN) break;
        size_t rec = FUSE_REC_ALIGN(offsetof(struct fuse_direntplus, dirent.name) + d->dirent.namelen);
        if (off + rec > g_st_reply_len) break;
        n++;
        off += (uint32_t)rec;
    }
    return n;
}

// test the inode table size limit
static void st_group_fd_bound(void) {
    char tmpl[] = "/tmp/rhizo-hostfsd-selftest-bound-XXXXXX";
    char *scratch = st_setup(tmpl);
    char root[96], path[160], name[32];
    snprintf(root, sizeof(root), "%s/root", scratch);
    if (mkdir(root, 0755) != 0) st_fatal("mkdir");
    for (int i = 0; i < 300; i++) {
        snprintf(path, sizeof(path), "%s/f%03d", root, i);
        write_file(path, "x");
    }

    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) st_fatal("getrlimit");
    if (rl.rlim_max != RLIM_INFINITY && rl.rlim_max < 96) st_fatal("a hard RLIMIT_NOFILE under 96");
    rl.rlim_cur = 96;
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) st_fatal("setrlimit");

    inode_table_init(root);

    uint64_t first = 0;
    int registered = 0, refused = 0, other = 0;
    for (int i = 0; i < 300; i++) {
        snprintf(name, sizeof(name), "f%03d", i);
        st_lookup(FUSE_ROOT_ID, name);
        if (st_errno() == 0) {
            registered++;
            if (!first) first = ((const struct fuse_entry_out *)st_body())->nodeid;
        } else if (st_errno() == EMFILE) {
            refused++;
        } else {
            other++;
        }
    }
    SELFTEST_CHECK(registered >= 16 && refused > 0 && other == 0,
                   "dispatch: LOOKUP fills the inode table to its bound and then refuses with EMFILE");

    int probe = open("/dev/null", O_RDONLY);
    SELFTEST_CHECK(probe >= 0,
                   "dispatch: descriptors remain for real work once the inode bound has engaged");
    if (probe >= 0) close(probe);

    st_open(FUSE_OPEN, first, O_RDONLY, sizeof(struct fuse_open_in));
    int open_ok = (st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_open_out));
    SELFTEST_CHECK(open_ok, "dispatch: an OPEN still succeeds once the inode bound has engaged");
    if (open_ok) {
        uint64_t fh = ((const struct fuse_open_out *)st_body())->fh;
        st_read(FUSE_READ, first, fh, 0, 8);
        SELFTEST_CHECK(st_errno() == 0 && g_st_reply_len == 1,
                       "dispatch: that OPEN's handle still reads the file's bytes");
        st_release(FUSE_RELEASE, first, fh);
    }

    st_lookup(FUSE_ROOT_ID, "f000");
    SELFTEST_CHECK(st_errno() == 0,
                   "dispatch: a LOOKUP of an already-registered name still succeeds at the bound");

    uint64_t dh = 0;
    st_open(FUSE_OPENDIR, FUSE_ROOT_ID, O_RDONLY, sizeof(struct fuse_open_in));
    if (st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_open_out))
        dh = ((const struct fuse_open_out *)st_body())->fh;
    st_read(FUSE_READDIRPLUS, FUSE_ROOT_ID, dh, 0, 4096);
    SELFTEST_CHECK(st_errno() == 0 && st_direntplus_count() > 0,
                   "dispatch: READDIRPLUS still lists names once the inode bound has engaged");
    if (dh) st_release(FUSE_RELEASEDIR, FUSE_ROOT_ID, dh);

    st_forget(first, 2);
    st_lookup(FUSE_ROOT_ID, "f299");
    SELFTEST_CHECK(st_errno() == 0, "dispatch: forgetting an inode returns its budget to the table");

    st_rm_rf(scratch);
}

// test OPENDIR body length checks
static void st_group_opendir_len(void) {
    char tmpl[] = "/tmp/rhizo-hostfsd-selftest-opendir-XXXXXX";
    char *scratch = st_setup(tmpl);
    char root[96], path[160];
    snprintf(root, sizeof(root), "%s/root", scratch);
    if (mkdir(root, 0755) != 0) st_fatal("mkdir");
    snprintf(path, sizeof(path), "%s/hello.txt", root);
    write_file(path, "hello world");
    inode_table_init(root);

    st_open(FUSE_OPENDIR, FUSE_ROOT_ID, O_RDONLY, 0);
    SELFTEST_CHECK(st_errno() == EINVAL, "dispatch: OPENDIR with an empty body is refused EINVAL");
    st_open(FUSE_OPENDIR, FUSE_ROOT_ID, O_RDONLY, sizeof(struct fuse_open_in) - 1);
    SELFTEST_CHECK(st_errno() == EINVAL,
                   "dispatch: OPENDIR with a body shorter than fuse_open_in is refused EINVAL");

    uint64_t dh = 0;
    st_open(FUSE_OPENDIR, FUSE_ROOT_ID, O_RDONLY, sizeof(struct fuse_open_in));
    int ok = (st_errno() == 0 && g_st_reply_len == sizeof(struct fuse_open_out));
    if (ok) dh = ((const struct fuse_open_out *)st_body())->fh;
    SELFTEST_CHECK(ok, "dispatch: OPENDIR with a whole body answers a handle");
    char names[16][NAME_MAX_LEN + 1];
    st_read(FUSE_READDIR, FUSE_ROOT_ID, dh, 0, 4096);
    SELFTEST_CHECK(st_errno() == 0 && st_dirents(names, 16, NULL) == 3,
                   "dispatch: that handle lists the directory");
    st_release(FUSE_RELEASEDIR, FUSE_ROOT_ID, dh);

    uint64_t file = 0;
    st_lookup(FUSE_ROOT_ID, "hello.txt");
    if (st_errno() == 0) file = ((const struct fuse_entry_out *)st_body())->nodeid;
    st_open(FUSE_OPENDIR, file, O_RDONLY, sizeof(struct fuse_open_in));
    SELFTEST_CHECK(st_errno() == ENOTDIR, "dispatch: OPENDIR of a file is refused ENOTDIR");

    st_rm_rf(scratch);
}

// test a partial reply write
static void st_group_short_reply(void) {
    signal(SIGPIPE, SIG_IGN);
    int data_pipe[2], count_pipe[2];
    if (pipe(data_pipe) != 0 || pipe(count_pipe) != 0) st_fatal("pipe");
    if (fcntl(data_pipe[1], F_SETPIPE_SZ, 4096) < 0) st_fatal("F_SETPIPE_SZ");

    const uint32_t payload_len = 40000;
    uint8_t *payload = malloc(payload_len);
    if (!payload) st_fatal("malloc");
    for (uint32_t i = 0; i < payload_len; i++) payload[i] = (uint8_t)(i & 0xff);

    fflush(NULL);
    pid_t pid = fork();
    if (pid < 0) st_fatal("fork");
    if (pid == 0) {
        close(data_pipe[1]);
        close(count_pipe[0]);
        uint64_t total = 0;
        uint8_t buf[4096];
        ssize_t r;
        while ((r = read(data_pipe[0], buf, sizeof(buf))) > 0) total += (uint64_t)r;
        ssize_t w = write(count_pipe[1], &total, sizeof(total));
        _exit(w == (ssize_t)sizeof(total) ? 0 : 1);
    }
    close(data_pipe[0]);
    close(count_pipe[1]);
    int flags = fcntl(data_pipe[1], F_GETFL);
    if (flags < 0 || fcntl(data_pipe[1], F_SETFL, flags | O_NONBLOCK) != 0) st_fatal("O_NONBLOCK");

    g_fuse_fd = data_pipe[1];
    raw_reply(4242, 0, payload, payload_len);
    close(data_pipe[1]);

    uint64_t total = 0;
    ssize_t got = read(count_pipe[0], &total, sizeof(total));
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) { }
    SELFTEST_CHECK(got == (ssize_t)sizeof(total) &&
                       total == payload_len + sizeof(struct fuse_out_header),
                   "dispatch: a reply larger than the descriptor takes at once is written whole");
    free(payload);
}

static uint64_t g_st_seccomp_dir = 0;
static uint64_t g_st_seccomp_file = 0;

// run FUSE requests under the seccomp filter
static void st_case_seccomp_sweep(void) {
    SELFTEST_CHECK(seccomp_install() == 0, "dispatch: the seccomp filter installs");
    SELFTEST_CHECK(seccomp_mode() == 2,
                   "dispatch: the seccomp filter is attached, by the kernel's own Seccomp: line");

    char names[32][NAME_MAX_LEN + 1];

    struct fuse_init_in ii;
    memset(&ii, 0, sizeof(ii));
    ii.major = FUSE_KERNEL_VERSION;
    ii.minor = FUSE_KERNEL_MINOR_VERSION;
    ii.max_readahead = 65536;
    st_call(FUSE_INIT, 0, &ii, sizeof(ii));
    SELFTEST_CHECK(st_errno() == 0 && g_st_reply_len >= sizeof(struct fuse_init_out),
                   "seccomp: INIT is answered under the filter");

    st_call(FUSE_GETATTR, FUSE_ROOT_ID, NULL, 0);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: GETATTR is answered under the filter");
    st_call(FUSE_STATFS, FUSE_ROOT_ID, NULL, 0);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: STATFS is answered under the filter");
    st_call(FUSE_ACCESS, FUSE_ROOT_ID, NULL, 0);
    st_call(FUSE_GETXATTR, FUSE_ROOT_ID, NULL, 0);
    st_call(FUSE_INTERRUPT, FUSE_ROOT_ID, NULL, 0);
    st_call(0xffff, FUSE_ROOT_ID, NULL, 0);
    SELFTEST_CHECK(st_errno() == ENOSYS, "seccomp: an unknown opcode is answered ENOSYS under the filter");

    st_lookup(FUSE_ROOT_ID, "hello.txt");
    SELFTEST_CHECK(st_errno() == 0, "seccomp: LOOKUP is answered under the filter");

    struct fuse_setattr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.valid = FATTR_SIZE | FATTR_MODE | FATTR_ATIME | FATTR_MTIME;
    sa.size = 4;
    sa.mode = S_IFREG | 0600;
    sa.atime = 1000000;
    sa.mtime = 1000000;
    st_call(FUSE_SETATTR, g_st_seccomp_file, &sa, sizeof(sa));
    SELFTEST_CHECK(st_errno() == 0, "seccomp: SETATTR truncates, chmods and stamps under the filter");

    uint64_t fh = 0;
    st_open(FUSE_OPEN, g_st_seccomp_file, O_RDWR, sizeof(struct fuse_open_in));
    if (st_errno() == 0) fh = ((const struct fuse_open_out *)st_body())->fh;
    st_write(g_st_seccomp_file, fh, 0, "abcd", 4);
    st_read(FUSE_READ, g_st_seccomp_file, fh, 0, 16);
    SELFTEST_CHECK(st_errno() == 0 && g_st_reply_len == 4,
                   "seccomp: OPEN, WRITE and READ round-trip under the filter");
    st_fsync(FUSE_FSYNC, g_st_seccomp_file, fh);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: FSYNC is answered under the filter");
    st_call(FUSE_FLUSH, g_st_seccomp_file, &sa, sizeof(struct fuse_flush_in));
    st_release(FUSE_RELEASE, g_st_seccomp_file, fh);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: FLUSH and RELEASE are answered under the filter");

    uint64_t dh = 0;
    st_open(FUSE_OPENDIR, FUSE_ROOT_ID, O_RDONLY, sizeof(struct fuse_open_in));
    if (st_errno() == 0) dh = ((const struct fuse_open_out *)st_body())->fh;
    st_read(FUSE_READDIR, FUSE_ROOT_ID, dh, 0, 4096);
    int listed = st_dirents(names, 32, NULL);
    st_read(FUSE_READDIRPLUS, FUSE_ROOT_ID, dh, 0, 4096);
    SELFTEST_CHECK(listed > 0 && st_errno() == 0 && st_direntplus_count() > 0,
                   "seccomp: READDIR and READDIRPLUS list under the filter");
    st_fsync(FUSE_FSYNCDIR, FUSE_ROOT_ID, dh);
    st_release(FUSE_RELEASEDIR, FUSE_ROOT_ID, dh);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: FSYNCDIR and RELEASEDIR are answered under the filter");

    st_create(FUSE_ROOT_ID, "created", O_WRONLY | O_CREAT | O_EXCL);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: CREATE is answered under the filter");
    if (st_errno() == 0) {
        const struct fuse_entry_out *eo = st_body();
        const struct fuse_open_out *oo =
            (const struct fuse_open_out *)((const uint8_t *)st_body() + sizeof(*eo));
        st_release(FUSE_RELEASE, eo->nodeid, oo->fh);
    }

    uint8_t mk[sizeof(struct fuse_mkdir_in) + 8];
    struct fuse_mkdir_in mi;
    memset(&mi, 0, sizeof(mi));
    mi.mode = S_IFDIR | 0755;
    memcpy(mk, &mi, sizeof(mi));
    memcpy(mk + sizeof(mi), "newdir", 7);
    st_call(FUSE_MKDIR, FUSE_ROOT_ID, mk, sizeof(mi) + 7);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: MKDIR is answered under the filter");

    uint8_t rn[sizeof(struct fuse_rename2_in) + 24];
    struct fuse_rename_in ri1;
    memset(&ri1, 0, sizeof(ri1));
    ri1.newdir = FUSE_ROOT_ID;
    memcpy(rn, &ri1, sizeof(ri1));
    memcpy(rn + sizeof(ri1), "newdir\0renamed", 15);
    st_call(FUSE_RENAME, FUSE_ROOT_ID, rn, sizeof(ri1) + 15);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: RENAME is answered under the filter");

    struct fuse_rename2_in ri2;
    memset(&ri2, 0, sizeof(ri2));
    ri2.flags = RENAME_NOREPLACE;
    ri2.newdir = FUSE_ROOT_ID;
    memcpy(rn, &ri2, sizeof(ri2));
    memcpy(rn + sizeof(ri2), "renamed\0back", 13);
    st_call(FUSE_RENAME2, FUSE_ROOT_ID, rn, sizeof(ri2) + 13);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: RENAME2 is answered under the filter");

    st_call(FUSE_RMDIR, FUSE_ROOT_ID, "back", 5);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: RMDIR is answered under the filter");
    st_call(FUSE_UNLINK, FUSE_ROOT_ID, "created", 8);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: UNLINK is answered under the filter");

    st_forget(g_st_seccomp_dir, 1);
    struct fuse_batch_forget_in bf;
    memset(&bf, 0, sizeof(bf));
    st_call(FUSE_BATCH_FORGET, 0, &bf, sizeof(bf));
    st_call(FUSE_DESTROY, 0, NULL, 0);
    SELFTEST_CHECK(st_errno() == 0, "seccomp: FORGET, BATCH_FORGET and DESTROY are answered under the filter");
}

// run the selftest group for the seccomp filter
static void st_group_seccomp(void) {
    char tmpl[] = "/tmp/rhizo-hostfsd-selftest-seccomp-XXXXXX";
    char *scratch = st_setup(tmpl);
    char root[96], path[160];
    snprintf(root, sizeof(root), "%s/root", scratch);
    if (mkdir(root, 0755) != 0) st_fatal("mkdir");
    snprintf(path, sizeof(path), "%s/hello.txt", root);
    write_file(path, "hello world");
    snprintf(path, sizeof(path), "%s/sub", root);
    if (mkdir(path, 0755) != 0) st_fatal("mkdir sub");
    inode_table_init(root);

    st_lookup(FUSE_ROOT_ID, "hello.txt");
    if (st_errno() == 0) g_st_seccomp_file = ((const struct fuse_entry_out *)st_body())->nodeid;
    st_lookup(FUSE_ROOT_ID, "sub");
    if (st_errno() == 0) g_st_seccomp_dir = ((const struct fuse_entry_out *)st_body())->nodeid;
    SELFTEST_CHECK(g_st_seccomp_file && g_st_seccomp_dir,
                   "dispatch: the seccomp sweep has a file and a directory to work on");

    st_group("seccomp opcode sweep", st_case_seccomp_sweep);
    st_rm_rf(scratch);
}

// test concurrent reads on different handles
static void st_case_concurrent_io(uint64_t file_a, uint64_t file_b) {
    uint64_t fh_a = 0, fh_b = 0;
    st_open(FUSE_OPEN, file_a, O_RDONLY, sizeof(struct fuse_open_in));
    if (st_errno() == 0) fh_a = ((const struct fuse_open_out *)st_body())->fh;
    st_open(FUSE_OPEN, file_b, O_RDONLY, sizeof(struct fuse_open_in));
    if (st_errno() == 0) fh_b = ((const struct fuse_open_out *)st_body())->fh;
    SELFTEST_CHECK(fh_a && fh_b, "dispatch: concurrent-io has two open handles to work on");

    g_st_track_order = 1;
    g_st_order_n = 0;
    g_st_gate_open = 0;
    g_st_block_fh = fh_a;

    struct fuse_read_in ria;
    memset(&ria, 0, sizeof(ria));
    ria.fh = fh_a;
    ria.size = 16;
    st_send(FUSE_READ, file_a, &ria, sizeof(ria));

    struct fuse_read_in rib;
    memset(&rib, 0, sizeof(rib));
    rib.fh = fh_b;
    rib.size = 16;
    st_send(FUSE_READ, file_b, &rib, sizeof(rib));

    int seen = 0;
    for (int i = 0; i < 2000 && !seen; i++) {
        pthread_mutex_lock(&g_st_order_lock);
        seen = (g_st_order_n >= 1);
        pthread_mutex_unlock(&g_st_order_lock);
        if (!seen) usleep(1000);
    }
    SELFTEST_CHECK(seen && g_st_order[0] == fh_b,
                   "dispatch: a slow READ does not block a concurrent READ on a different handle");

    pthread_mutex_lock(&g_st_gate_lock);
    g_st_gate_open = 1;
    pthread_cond_broadcast(&g_st_gate_cond);
    pthread_mutex_unlock(&g_st_gate_lock);
    wait_for_io_workers();

    g_st_track_order = 0;
    g_st_block_fh = 0;

    st_release(FUSE_RELEASE, file_a, fh_a);
    st_release(FUSE_RELEASE, file_b, fh_b);
}

// run the selftest group for concurrent I/O
static void st_group_concurrent_io(void) {
    char tmpl[] = "/tmp/rhizo-hostfsd-selftest-concurrentio-XXXXXX";
    char *scratch = st_setup(tmpl);
    char root[96], path[160];
    snprintf(root, sizeof(root), "%s/root", scratch);
    if (mkdir(root, 0755) != 0) st_fatal("mkdir");
    snprintf(path, sizeof(path), "%s/a.txt", root);
    write_file(path, "aaaaaaaaaaaaaaaa");
    snprintf(path, sizeof(path), "%s/b.txt", root);
    write_file(path, "bbbbbbbbbbbbbbbb");
    inode_table_init(root);

    st_lookup(FUSE_ROOT_ID, "a.txt");
    uint64_t file_a = st_errno() == 0 ? ((const struct fuse_entry_out *)st_body())->nodeid : 0;
    st_lookup(FUSE_ROOT_ID, "b.txt");
    uint64_t file_b = st_errno() == 0 ? ((const struct fuse_entry_out *)st_body())->nodeid : 0;
    SELFTEST_CHECK(file_a && file_b, "dispatch: concurrent-io has two files to look up");

    st_case_concurrent_io(file_a, file_b);
    st_rm_rf(scratch);
}

static void selftest_run(void) {
    st_group("create", st_group_create);
    st_group("handles", st_group_handles);
    st_group("descriptor bound", st_group_fd_bound);
    st_group("opendir body length", st_group_opendir_len);
    st_group("short reply", st_group_short_reply);
    st_group("seccomp", st_group_seccomp);
    st_group("concurrent io", st_group_concurrent_io);

    SELFTEST_CHECK(st_no_new_privs() == 1,
                   "no_new_privs is set on the process the kernel sees, before anything else runs");

    char tmpl[] = "/tmp/rhizo-hostfsd-selftest-XXXXXX";
    char *root = mkdtemp(tmpl);
    if (!root) { fprintf(stderr, "selftest: mkdtemp failed: %s\n", strerror(errno)); exit(1); }
    fprintf(stderr, "SELFTEST: using temp root %s\n", root);

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/hello.txt", root);
    write_file(path, "hello world");

    snprintf(path, sizeof(path), "%s/sub", root);
    if (mkdir(path, 0755) != 0) { fprintf(stderr, "selftest setup: mkdir sub failed\n"); exit(1); }

    char outside_tmpl[] = "/tmp/rhizo-hostfsd-selftest-outside-XXXXXX";
    char *outside = mkdtemp(outside_tmpl);
    if (!outside) { fprintf(stderr, "selftest setup: mkdtemp outside failed\n"); exit(1); }
    char outside_secret[PATH_MAX];
    snprintf(outside_secret, sizeof(outside_secret), "%s/secret.txt", outside);
    write_file(outside_secret, "should never be reachable through root");

    char link_target[PATH_MAX];
    snprintf(link_target, sizeof(link_target), "../%s/secret.txt", strrchr(outside, '/') + 1);
    snprintf(path, sizeof(path), "%s/escape_link", root);
    if (symlink(link_target, path) != 0) { fprintf(stderr, "selftest setup: symlink failed\n"); exit(1); }

    char hardlink_path[PATH_MAX];
    snprintf(hardlink_path, sizeof(hardlink_path), "%s/hello2.txt", root);
    char hello_path[PATH_MAX];
    snprintf(hello_path, sizeof(hello_path), "%s/hello.txt", root);
    if (link(hello_path, hardlink_path) != 0) { fprintf(stderr, "selftest setup: link failed\n"); exit(1); }

    g_cfg.uid = 7777;
    g_cfg.gid = 8888;
    g_cfg.file_mode = 0640;
    g_cfg.dir_mode = 0750;
    inode_table_init(root);

    SELFTEST_CHECK(name_ok("hello.txt") == 1, "name_ok accepts a plain name");
    SELFTEST_CHECK(name_ok("..") == 0, "name_ok rejects \"..\"");
    SELFTEST_CHECK(name_ok(".") == 0, "name_ok rejects \".\"");
    SELFTEST_CHECK(name_ok("a/b") == 0, "name_ok rejects an embedded '/'");
    SELFTEST_CHECK(name_ok("") == 0, "name_ok rejects an empty name");

    struct inode *child;
    struct stat st;
    int rc = resolve_and_register(g_root, "..", &child, &st);
    SELFTEST_CHECK(rc == ENOENT, "resolve_and_register refuses \"..\" as a child name");

    rc = resolve_and_register(g_root, "../etc/passwd", &child, &st);
    SELFTEST_CHECK(rc == ENOENT, "resolve_and_register refuses a name containing '/'");

    rc = resolve_and_register(g_root, "escape_link", &child, &st);
    SELFTEST_CHECK(rc == ENOENT, "resolve_and_register refuses a symlink instead of following it out of root");

    struct inode *hello = NULL;
    rc = resolve_and_register(g_root, "hello.txt", &hello, &st);
    SELFTEST_CHECK(rc == 0 && hello != NULL, "resolve_and_register succeeds for a real file");
    if (hello) {
        SELFTEST_CHECK(hello->refcount == 1, "first lookup has refcount 1");
        uint64_t hello_nodeid = hello->nodeid;

        struct inode *sub = NULL;
        rc = resolve_and_register(g_root, "sub", &sub, &st);
        SELFTEST_CHECK(rc == 0 && sub != NULL && sub->is_dir == 1, "resolve_and_register succeeds for a real directory");

        struct fuse_attr attr;
        fill_fuse_attr(&attr, hello, &st);
        struct stat hello_st;
        SELFTEST_CHECK(fstatat(hello->path_fd, "", &hello_st, AT_EMPTY_PATH) == 0, "fstatat on hello's path_fd succeeds");
        fill_fuse_attr(&attr, hello, &hello_st);
        SELFTEST_CHECK(attr.uid == 7777 && attr.gid == 8888, "reported attrs use the configured uid/gid, not the real ones");
        SELFTEST_CHECK((attr.mode & 07777) == 0640, "reported mode uses the configured file-mode");
        SELFTEST_CHECK(hello_st.st_uid == getuid(), "the real on-disk owner is untouched (still the process's own uid)");

        struct inode *hello2 = NULL;
        rc = resolve_and_register(g_root, "hello2.txt", &hello2, &st);
        SELFTEST_CHECK(rc == 0 && hello2 == hello, "a hardlink resolves to the SAME nodeid as the original name");
        SELFTEST_CHECK(hello->refcount == 2, "refcount reflects both lookups after the hardlink resolve");

        inode_forget(hello_nodeid, 2);
        struct inode *hello_again = NULL;
        rc = resolve_and_register(g_root, "hello.txt", &hello_again, &st);
        SELFTEST_CHECK(rc == 0 && hello_again != NULL, "hello.txt resolves again after being fully forgotten");
        SELFTEST_CHECK(hello_again->nodeid != hello_nodeid, "a fully-forgotten inode is freed: re-lookup allocates a new nodeid");
    }

    struct inode *w = NULL;
    rc = resolve_and_register(g_root, "hello.txt", &w, &st);
    SELFTEST_CHECK(rc == 0, "re-resolve hello.txt for I/O test");
    if (w) {
        int fd = reopen_via_procpath(w->path_fd, O_RDWR, 0);
        SELFTEST_CHECK(fd >= 0, "reopen_via_procpath opens a real read/write fd");
        if (fd >= 0) {
            char buf[32];
            ssize_t r = pread(fd, buf, sizeof(buf), 0);
            SELFTEST_CHECK(r == (ssize_t)strlen("hello world") && memcmp(buf, "hello world", (size_t)r) == 0,
                            "pread through the reopened fd returns the real file's exact bytes");
            SELFTEST_CHECK(ftruncate(fd, 5) == 0, "ftruncate through the reopened fd succeeds");
            struct stat trunc_st;
            SELFTEST_CHECK(fstat(fd, &trunc_st) == 0 && trunc_st.st_size == 5, "truncate took effect for real, on disk");
            close(fd);
        }
    }

    if (mkdirat(g_root->path_fd, "newdir", 0750) == 0) {
        struct inode *nd = NULL;
        rc = resolve_and_register(g_root, "newdir", &nd, &st);
        SELFTEST_CHECK(rc == 0 && nd && nd->is_dir, "mkdirat + resolve_and_register sees the new directory");
        SELFTEST_CHECK(renameat2(g_root->path_fd, "newdir", g_root->path_fd, "renamed_dir", 0) == 0,
                        "renameat2 through retained parent fds succeeds");
        SELFTEST_CHECK(unlinkat(g_root->path_fd, "renamed_dir", AT_REMOVEDIR) == 0,
                        "unlinkat(AT_REMOVEDIR) removes the renamed directory");
    } else {
        SELFTEST_CHECK(0, "mkdirat for rename/rmdir test");
    }

    SELFTEST_CHECK(name_ok("..") == 0, "name_ok still rejects \"..\" before any mkdirat/unlinkat/renameat2 call would run");

    st_rm_rf(root);
    st_rm_rf(outside);

    if (g_selftest_failures > 0) {
        fprintf(stderr, "SELFTEST: %d assertion(s) FAILED\n", g_selftest_failures);
        exit(1);
    }
    fprintf(stderr, "SELFTEST: all assertions passed\n");
}


// print the usage text to stderr
static void usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s --fd N --root DIR [--uid N] [--gid N] [--file-mode OCTAL]\n"
        "          [--dir-mode OCTAL] [--foreground] [--log PATH]\n"
        "       %s --selftest\n"
        "       %s --help\n",
        argv0, argv0, argv0);
}

// parse a string as an octal mode
static uint32_t parse_octal_mode(const char *s) {
    return (uint32_t)strtoul(s, NULL, 8);
}

// parse options and serve the FUSE descriptor
int main(int argc, char **argv) {
    static const struct option long_opts[] = {
        {"fd", required_argument, NULL, 'f'},
        {"root", required_argument, NULL, 'r'},
        {"uid", required_argument, NULL, 'u'},
        {"gid", required_argument, NULL, 'g'},
        {"file-mode", required_argument, NULL, 'm'},
        {"dir-mode", required_argument, NULL, 'd'},
        {"foreground", no_argument, NULL, 'F'},
        {"log", required_argument, NULL, 'l'},
        {"selftest", no_argument, NULL, 'S'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0},
    };

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        fprintf(stderr, "rhizo-hostfsd: PR_SET_NO_NEW_PRIVS failed: %s\n", strerror(errno));
    }

    int do_selftest = 0;
    int have_fd = 0, have_root = 0;

    int c;
    while ((c = getopt_long(argc, argv, "", long_opts, NULL)) != -1) {
        switch (c) {
            case 'f': g_cfg.fd = atoi(optarg); have_fd = 1; break;
            case 'r': g_cfg.root = optarg; have_root = 1; break;
            case 'u': g_cfg.uid = (uint32_t)strtoul(optarg, NULL, 10); break;
            case 'g': g_cfg.gid = (uint32_t)strtoul(optarg, NULL, 10); break;
            case 'm': g_cfg.file_mode = parse_octal_mode(optarg); break;
            case 'd': g_cfg.dir_mode = parse_octal_mode(optarg); break;
            case 'F': g_cfg.foreground = 1; break;
            case 'l': g_cfg.log_path = optarg; break;
            case 'S': do_selftest = 1; break;
            case 'h': usage(argv[0]); return 0;
            default: usage(argv[0]); return 2;
        }
    }

    if (do_selftest) {
        selftest_run();
        return 0;
    }

    if (!have_fd || !have_root) {
        fprintf(stderr, "rhizo-hostfsd: --fd and --root are required\n");
        usage(argv[0]);
        return 2;
    }
    if (g_cfg.fd < 0) {
        fprintf(stderr, "rhizo-hostfsd: --fd must be a non-negative integer\n");
        return 2;
    }

    if (g_cfg.fd <= 2) {
        int moved = fcntl(g_cfg.fd, F_DUPFD_CLOEXEC, 3);
        if (moved < 0) {
            fprintf(stderr, "rhizo-hostfsd: could not move --fd %d out of the stdio range: %s\n",
                    g_cfg.fd, strerror(errno));
            return 1;
        }
        close(g_cfg.fd);
        g_cfg.fd = moved;
    }
    g_fuse_fd = g_cfg.fd;

    if (g_cfg.log_path) {
        g_log = fopen(g_cfg.log_path, "a");
        if (!g_log) {
            fprintf(stderr, "rhizo-hostfsd: cannot open --log %s: %s\n", g_cfg.log_path, strerror(errno));
            return 1;
        }
        setlinebuf(g_log);
    }

    signal(SIGPIPE, SIG_IGN);

    if (!g_cfg.foreground) {
        pid_t pid = fork();
        if (pid < 0) {
            logf_err("fork failed: %s", strerror(errno));
            return 1;
        }
        if (pid > 0) {
            printf("%d\n", pid);
            fflush(stdout);
            return 0;
        }
        if (setsid() < 0) {
            logf_err("setsid failed: %s", strerror(errno));
            _exit(1);
        }
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            if (!g_log) dup2(devnull, STDOUT_FILENO);
            if (!g_log) dup2(devnull, STDERR_FILENO);
            if (devnull > 2) close(devnull);
        }
    }

    rz_log("starting: root=%s uid=%u gid=%u file_mode=0%o dir_mode=0%o fd=%d",
         g_cfg.root, g_cfg.uid, g_cfg.gid, g_cfg.file_mode, g_cfg.dir_mode, g_fuse_fd);

    raise_nofile();
    inode_table_init(g_cfg.root);
    rz_log("descriptor budget: at most %u live inodes and %u open handles",
         g_max_inodes, g_max_handles);

    if (seccomp_install() != 0) {
        logf_err("refusing to serve without the syscall filter");
        return 1;
    }
    serve_forever();

    rz_log("exiting");
    if (g_log) fclose(g_log);
    return 0;
}
