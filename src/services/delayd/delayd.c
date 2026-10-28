#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

typedef uint64_t u64;
typedef int64_t s64;
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;

#define FLOOR_NS 500000ULL
#define SELINUX_MODE_EXIT 78
#define GAP_NS 1000000ULL
#define MAX_SPAN_NS 100000000ULL
#define DELAYED_WP_US 2000ULL
#define WATERMARK_NS 5000000ULL
#define TICK_NS 20000000ULL
#define SPAN_SCAN_NS 10000000ULL
#define RESCAN_NS 2000000000ULL
#define RESCAN_MIN_NS 250000000ULL
#define C_INTERVAL_NS 200000000ULL
#define STATS_NS 100000000ULL
#define STATUS_NS 1000000000ULL
#define PKT_MAX 4096
#define CONN_QUEUE_MAX (4u << 20)
#define QUEUE_CAP_EVENTS 65536
#define NAME_MAX_ANDROID 127
#define TASK_TAB_BITS 16
#define TASK_CAP 2000000

#define INIT_CTX "u:r:init:s0"
#define HOST_DELAY_CTX "u:r:rhizo_host_delay:s0"
#define DELAYD_CTX "u:r:rhizo_delayd:s0"
#define ENTERING_ENV "RHIZO_DELAYD_ENTERING"

// return the boottime clock in nanoseconds
static u64 boottime_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_BOOTTIME, &ts);
	return (u64)ts.tv_sec * 1000000000ULL + (u64)ts.tv_nsec;
}

static int g_quiet;

// print a prefixed message to stderr unless quiet
static void logmsg(const char *fmt, ...)
{
	va_list ap;
	if (g_quiet)
		return;
	va_start(ap, fmt);
	fputs("rhizo-delayd: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	fflush(stderr);
}

// exit with an out-of-memory message when an allocation failed
static void *oom_check(void *q)
{
	if (!q) {
		fputs("rhizo-delayd: out of memory\n", stderr);
		_exit(70);
	}
	return q;
}

// reallocate memory, exiting when it fails
static void *xrealloc(void *p, size_t n)
{
	return oom_check(realloc(p, n ? n : 1));
}

// allocate zeroed memory, exiting when it fails
static void *xcalloc(size_t n, size_t m)
{
	return oom_check(calloc(n ? n : 1, m ? m : 1));
}

// read a file into a buffer and return its length, or -1
static int read_text(const char *path, char *buf, size_t cap)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	size_t n = 0;
	for (;;) {
		ssize_t r = read(fd, buf + n, cap - 1 - n);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			break;
		n += (size_t)r;
		if (n >= cap - 1)
			break;
	}
	close(fd);
	buf[n] = 0;
	return (int)n;
}

// write a string to an existing file and return 0 on success
static int write_text(const char *path, const char *s)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	size_t n = strlen(s);
	ssize_t r = write(fd, s, n);
	int e = errno;
	close(fd);
	if (r != (ssize_t)n) {
		errno = r < 0 ? e : EIO;
		return -1;
	}
	return 0;
}

// copy src into dst
static void scopy(char *dst, size_t cap, const char *src)
{
	size_t n = strlen(src);
	if (n >= cap)
		n = cap - 1;
	memcpy(dst, src, n);
	dst[n] = 0;
}

// read a 32-bit value from unaligned bytes
static u32 rd32(const u8 *p) { u32 v; memcpy(&v, p, 4); return v; }
// read a 64-bit value from unaligned bytes
static u64 rd64(const u8 *p) { u64 v; memcpy(&v, p, 8); return v; }

// replace whitespace and control characters in a name with underscores
static void sanitize_name(char *s)
{
	for (; *s; s++)
		if ((unsigned char)*s <= ' ' || *s == 0x7f)
			*s = '_';
}

#define MAX_FIELDS 32
#define PRINT_FMT_CAP 4096

struct field {
	char name[40];
	int off, size, sgn;
	int loc;
};

struct evfmt {
	char name[40];
	int id;
	int nf;
	struct field f[MAX_FIELDS];
	char print_fmt[PRINT_FMT_CAP];
};

struct pagefmt {
	int ts_off, commit_off, commit_size, data_off, data_size, page_size;
	int type_padding, type_extend, type_stamp, data_max;
};

enum evk { K_SWITCH, K_WAKING, K_WAKEUP, K_WAKEUP_NEW, K_MIGRATE, K_FORK, K_EXIT, N_EV, K_LOSS = N_EV };

static const char *const EV_NAMES[N_EV] = {
	"sched_switch", "sched_waking", "sched_wakeup", "sched_wakeup_new",
	"sched_migrate_task", "sched_process_fork", "sched_process_exit",
};

// copy the next line into line
static int next_line(const char **pp, char *line, size_t cap)
{
	const char *p = *pp;
	if (!*p)
		return 0;
	size_t n = 0;
	while (*p && *p != '\n') {
		if (n + 1 < cap)
			line[n++] = *p;
		p++;
	}
	line[n] = 0;
	if (*p == '\n')
		p++;
	*pp = p;
	return 1;
}

// parse the number after a key in a line
static int num_after(const char *line, const char *key, long *out)
{
	const char *p = strstr(line, key);
	if (!p)
		return -1;
	p += strlen(key);
	while (*p == ' ' || *p == '\t')
		p++;
	char *end;
	long v = strtol(p, &end, 10);
	if (end == p)
		return -1;
	*out = v;
	return 0;
}

// parse a trace format field line
static int parse_field_line(const char *line, struct field *f)
{
	const char *fp = strstr(line, "field:");
	if (!fp)
		return 0;
	fp += 6;
	const char *semi = strchr(fp, ';');
	if (!semi)
		return 0;
	long off, size, sgn = 0;
	if (num_after(semi, "offset:", &off) || num_after(semi, "size:", &size))
		return 0;
	num_after(semi, "signed:", &sgn);
	const char *e = semi;
	while (e > fp && (e[-1] == ' ' || e[-1] == '\t'))
		e--;
	if (e > fp && e[-1] == ']') {
		while (e > fp && e[-1] != '[')
			e--;
		if (e > fp)
			e--;
	}
	const char *b = e;
	while (b > fp && (isalnum((unsigned char)b[-1]) || b[-1] == '_'))
		b--;
	if (b == e || (size_t)(e - b) >= sizeof f->name)
		return 0;
	memcpy(f->name, b, (size_t)(e - b));
	f->name[e - b] = 0;
	f->off = (int)off;
	f->size = (int)size;
	f->sgn = (int)sgn;
	f->loc = 0;
	for (const char *q = fp; q + 9 <= b; q++)
		if (!strncmp(q, "__data_loc", 10) || !strncmp(q, "__rel_loc", 9)) {
			f->loc = q[2] == 'd' ? 1 : 2;
			break;
		}
	return 1;
}

// parse the ring buffer header page format
static int parse_header_page(const char *text, struct pagefmt *pf)
{
	char line[512];
	struct field f;
	int have_ts = 0, have_commit = 0, have_data = 0;
	for (const char *p = text; next_line(&p, line, sizeof line);) {
		if (!parse_field_line(line, &f))
			continue;
		if (!strcmp(f.name, "timestamp")) {
			pf->ts_off = f.off;
			have_ts = f.size == 8;
		} else if (!strcmp(f.name, "commit")) {
			pf->commit_off = f.off;
			pf->commit_size = f.size;
			have_commit = f.size == 4 || f.size == 8;
		} else if (!strcmp(f.name, "data")) {
			pf->data_off = f.off;
			pf->data_size = f.size;
			have_data = f.size > 0;
		}
	}
	if (!have_ts || !have_commit || !have_data)
		return -1;
	pf->page_size = pf->data_off + pf->data_size;
	return 0;
}

// parse the ring buffer header_event format
static int parse_header_event(const char *text, struct pagefmt *pf)
{
	char line[256];
	long v;
	int got = 0, tl = 0, td = 0;
	for (const char *p = text; next_line(&p, line, sizeof line);) {
		const char *s = line;
		while (*s == ' ' || *s == '\t')
			s++;
		if (!strncmp(s, "type_len", 8) && strstr(s, "bits") && !num_after(s, ":", &v))
			tl = (int)v;
		else if (!strncmp(s, "time_delta", 10) && strstr(s, "bits") && !num_after(s, ":", &v))
			td = (int)v;
		else if (!strncmp(s, "padding", 7) && !num_after(s, "==", &v))
			pf->type_padding = (int)v, got |= 1;
		else if (!strncmp(s, "time_extend", 11) && !num_after(s, "==", &v))
			pf->type_extend = (int)v, got |= 2;
		else if (!strncmp(s, "time_stamp", 10) && !num_after(s, "==", &v))
			pf->type_stamp = (int)v, got |= 4;
		else if (!strncmp(s, "data max", 8) && !num_after(s, "==", &v))
			pf->data_max = (int)v, got |= 8;
	}
	return (got == 15 && tl == 5 && td == 27) ? 0 : -1;
}

// parse the format text of an event
static int parse_event_format(const char *text, struct evfmt *ev)
{
	char line[PRINT_FMT_CAP + 32];
	memset(ev, 0, sizeof *ev);
	ev->id = -1;
	for (const char *p = text; next_line(&p, line, sizeof line);) {
		if (!strncmp(line, "name:", 5)) {
			const char *s = line + 5;
			while (*s == ' ' || *s == '\t')
				s++;
			scopy(ev->name, sizeof ev->name, s);
		} else if (!strncmp(line, "ID:", 3)) {
			ev->id = atoi(line + 3);
		} else if (!strncmp(line, "print fmt:", 10)) {
			const char *s = line + 10;
			while (*s == ' ')
				s++;
			scopy(ev->print_fmt, sizeof ev->print_fmt, s);
		} else if (ev->nf < MAX_FIELDS && parse_field_line(line, &ev->f[ev->nf])) {
			ev->nf++;
		}
	}
	return (ev->id >= 0 && ev->nf > 0) ? 0 : -1;
}

struct fref {
	int off, size, sgn;
};

struct layout {
	struct pagefmt pg;
	int id[N_EV];
	struct fref sw_prev, sw_next, sw_state;
	struct fref wk_pid[3], wk_cpu[3];
	struct fref mg_pid, mg_orig, mg_dest;
	struct fref fk_parent, fk_child;
	struct fref ex_pid;
	u64 run_mask;
	u64 preempt_flag;
	int fmt_default;
	struct evfmt evfmt[N_EV];
};

// find a named field of an event format
static int bind_field(const struct evfmt *ev, const char *name, struct fref *r)
{
	for (int i = 0; i < ev->nf; i++)
		if (!strcmp(ev->f[i].name, name)) {
			r->off = ev->f[i].off;
			r->size = ev->f[i].size;
			r->sgn = ev->f[i].sgn;
			return 0;
		}
	logmsg("event %s has no field %s", ev->name, name);
	return -1;
}

// expression text with error flag
struct ex {
	const char *p;
	int err;
};
static u64 ex_or(struct ex *x);
// skip spaces and tabs in an expression
static void ex_ws(struct ex *x) { while (*x->p == ' ' || *x->p == '\t') x->p++; }
// parse a primary expression
static u64 ex_prim(struct ex *x)
{
	ex_ws(x);
	if (*x->p == '(') {
		x->p++;
		u64 v = ex_or(x);
		ex_ws(x);
		if (*x->p != ')')
			x->err = 1;
		else
			x->p++;
		return v;
	}
	if (*x->p == '~') {
		x->p++;
		return ~ex_prim(x);
	}
	if (isdigit((unsigned char)*x->p)) {
		char *end;
		u64 v = strtoull(x->p, &end, 0);
		x->p = end;
		while (*x->p == 'u' || *x->p == 'U' || *x->p == 'l' || *x->p == 'L')
			x->p++;
		return v;
	}
	x->err = 1;
	return 0;
}
// parse additions and subtractions
static u64 ex_add(struct ex *x)
{
	u64 v = ex_prim(x);
	for (;;) {
		ex_ws(x);
		if (*x->p == '+') { x->p++; v += ex_prim(x); }
		else if (*x->p == '-') { x->p++; v -= ex_prim(x); }
		else return v;
	}
}
// parse shifts
static u64 ex_shift(struct ex *x)
{
	u64 v = ex_add(x);
	for (;;) {
		ex_ws(x);
		if (x->p[0] == '<' && x->p[1] == '<') { x->p += 2; v <<= (ex_add(x) & 63); }
		else if (x->p[0] == '>' && x->p[1] == '>') { x->p += 2; v >>= (ex_add(x) & 63); }
		else return v;
	}
}
// parse bitwise and
static u64 ex_and(struct ex *x)
{
	u64 v = ex_shift(x);
	for (;;) {
		ex_ws(x);
		if (x->p[0] == '&' && x->p[1] != '&') { x->p++; v &= ex_shift(x); }
		else return v;
	}
}
// parse bitwise or
static u64 ex_or(struct ex *x)
{
	u64 v = ex_and(x);
	for (;;) {
		ex_ws(x);
		if (x->p[0] == '|' && x->p[1] != '|') { x->p++; v |= ex_and(x); }
		else return v;
	}
}

// set run_mask and preempt_flag from the print fmt
static void bind_state_masks(struct layout *L, const struct evfmt *sw)
{
	static const char key[] = "REC->prev_state & ";
	const char *first = strstr(sw->print_fmt, key), *last = NULL;
	for (const char *p = first; p; p = strstr(p + 1, key))
		last = p;
	L->run_mask = 0xff;
	L->preempt_flag = 0x100;
	L->fmt_default = 1;
	if (!first || first == last)
		return;
	struct ex a = { first + sizeof key - 1, 0 }, b = { last + sizeof key - 1, 0 };
	u64 mask = ex_shift(&a), flag = ex_shift(&b);
	if (a.err || b.err || !mask || !flag)
		return;
	L->run_mask = mask;
	L->preempt_flag = flag;
	L->fmt_default = 0;
}

// build the layout of the header page and the event formats
static int layout_build(struct layout *L, const char *header_page, const char *header_event,
			const char *const fmt_text[N_EV])
{
	memset(L, 0, sizeof *L);
	if (parse_header_page(header_page, &L->pg)) {
		logmsg("header_page not understood");
		return -1;
	}
	if (parse_header_event(header_event, &L->pg)) {
		logmsg("header_event is not the compressed 5/27-bit header");
		return -1;
	}
	struct evfmt *ev = L->evfmt;
	for (int i = 0; i < N_EV; i++) {
		if (parse_event_format(fmt_text[i], &ev[i])) {
			logmsg("format of %s not understood", EV_NAMES[i]);
			return -1;
		}
		L->id[i] = ev[i].id;
	}
	int bad = 0;
	bad |= bind_field(&ev[K_SWITCH], "prev_pid", &L->sw_prev);
	bad |= bind_field(&ev[K_SWITCH], "next_pid", &L->sw_next);
	bad |= bind_field(&ev[K_SWITCH], "prev_state", &L->sw_state);
	for (int i = 0; i < 3; i++) {
		bad |= bind_field(&ev[K_WAKING + i], "pid", &L->wk_pid[i]);
		bad |= bind_field(&ev[K_WAKING + i], "target_cpu", &L->wk_cpu[i]);
	}
	bad |= bind_field(&ev[K_MIGRATE], "pid", &L->mg_pid);
	bad |= bind_field(&ev[K_MIGRATE], "orig_cpu", &L->mg_orig);
	bad |= bind_field(&ev[K_MIGRATE], "dest_cpu", &L->mg_dest);
	bad |= bind_field(&ev[K_FORK], "parent_pid", &L->fk_parent);
	bad |= bind_field(&ev[K_FORK], "child_pid", &L->fk_child);
	bad |= bind_field(&ev[K_EXIT], "pid", &L->ex_pid);
	if (bad)
		return -1;
	bind_state_masks(L, &ev[K_SWITCH]);
	return 0;
}

struct rawev {
	u64 ts;
	int cpu;
	int id;
	const u8 *rec;
	unsigned len;
};
typedef void (*raw_cb)(void *ctx, const struct rawev *r);

struct decode_stats {
	u64 pages, events, padding, malformed, missed_pages, missed_events;
};

#define RB_MISSED_EVENTS (1u << 31)
#define RB_MISSED_STORED (1u << 30)

// decode the events of a ring buffer page
static void decode_page(const struct pagefmt *pf, int cpu, const u8 *page, size_t n, raw_cb cb,
			void *ctx, struct decode_stats *st)
{
	if (n < (size_t)pf->page_size) {
		st->malformed++;
		return;
	}
	st->pages++;
	u64 ts = rd64(page + pf->ts_off);
	u64 commit = pf->commit_size == 8 ? rd64(page + pf->commit_off) : rd32(page + pf->commit_off);
	unsigned flags = (unsigned)(commit & (RB_MISSED_EVENTS | RB_MISSED_STORED));
	size_t len = (size_t)(commit & ~(u64)(RB_MISSED_EVENTS | RB_MISSED_STORED));
	if (len > (size_t)pf->data_size)
		len = (size_t)pf->data_size;
	const u8 *data = page + pf->data_off;
	if (flags & RB_MISSED_EVENTS) {
		st->missed_pages++;
		if ((flags & RB_MISSED_STORED) && len + 8 <= (size_t)pf->data_size)
			st->missed_events += rd64(data + len);
		struct rawev m = { ts, cpu, -1, NULL, 0 };
		cb(ctx, &m);
	}
	size_t off = 0;
	while (off + 4 <= len) {
		u32 h = rd32(data + off);
		int tl = (int)(h & 0x1f);
		u64 td = h >> 5;
		if (tl <= pf->data_max) {
			size_t size, hdr;
			if (tl == 0) {
				if (off + 8 > len) { st->malformed++; break; }
				u32 alen = rd32(data + off + 4);
				if (alen < 4) { st->malformed++; break; }
				size = (size_t)alen + 4;
				hdr = 8;
			} else {
				size = (size_t)tl * 4 + 4;
				hdr = 4;
			}
			if (off + size > len || size < hdr) { st->malformed++; break; }
			ts += td;
			if (size - hdr >= 2) {
				struct rawev r = { ts, cpu, (int)(rd32(data + off + hdr) & 0xffff), data + off + hdr,
						   (unsigned)(size - hdr) };
				st->events++;
				cb(ctx, &r);
			} else {
				st->malformed++;
			}
			off += size;
		} else if (tl == pf->type_padding) {
			if (td == 0)
				break;
			if (off + 8 > len)
				break;
			size_t size = (size_t)rd32(data + off + 4) + 4;
			if (size < 8 || off + size > len)
				break;
			ts += td;
			st->padding++;
			off += size;
		} else if (tl == pf->type_extend) {
			if (off + 8 > len) { st->malformed++; break; }
			ts += td + ((u64)rd32(data + off + 4) << 27);
			off += 8;
		} else if (tl == pf->type_stamp) {
			if (off + 8 > len) { st->malformed++; break; }
			ts = td + ((u64)rd32(data + off + 4) << 27);
			off += 8;
		} else {
			st->malformed++;
			break;
		}
	}
}

struct ev {
	u64 ts;
	int a, b, c, d;
	u8 kind;
	u16 cpu;
};

// read a field value from a record, or -1 if it is out of range
static int fval(const u8 *rec, unsigned len, const struct fref *f, s64 *out)
{
	if (f->off < 0 || f->off + f->size > (int)len)
		return -1;
	const u8 *p = rec + f->off;
	switch (f->size) {
	case 1: *out = f->sgn ? (s64)(int8_t)p[0] : (s64)p[0]; break;
	case 2: { u16 v; memcpy(&v, p, 2); *out = f->sgn ? (s64)(int16_t)v : (s64)v; break; }
	case 4: { u32 v; memcpy(&v, p, 4); *out = f->sgn ? (s64)(int32_t)v : (s64)v; break; }
	case 8: { u64 v; memcpy(&v, p, 8); *out = (s64)v; break; }
	default: return -1;
	}
	return 0;
}

// convert a ring buffer record into an ev
static int raw_to_ev(const struct layout *L, const struct rawev *r, struct ev *o)
{
	int k;
	for (k = 0; k < N_EV; k++)
		if (L->id[k] == r->id)
			break;
	if (k == N_EV)
		return 0;
	memset(o, 0, sizeof *o);
	o->ts = r->ts;
	o->cpu = (u16)r->cpu;
	o->kind = (u8)k;
	s64 a = 0, b = 0, c = 0;
	int bad = 0;
	switch (k) {
	case K_SWITCH:
		bad |= fval(r->rec, r->len, &L->sw_prev, &a);
		bad |= fval(r->rec, r->len, &L->sw_next, &b);
		bad |= fval(r->rec, r->len, &L->sw_state, &c);
		c = ((u64)c & L->run_mask & ~L->preempt_flag) == 0;
		break;
	case K_WAKING: case K_WAKEUP: case K_WAKEUP_NEW:
		bad |= fval(r->rec, r->len, &L->wk_pid[k - K_WAKING], &a);
		bad |= fval(r->rec, r->len, &L->wk_cpu[k - K_WAKING], &b);
		break;
	case K_MIGRATE:
		bad |= fval(r->rec, r->len, &L->mg_pid, &a);
		bad |= fval(r->rec, r->len, &L->mg_orig, &b);
		bad |= fval(r->rec, r->len, &L->mg_dest, &c);
		break;
	case K_FORK:
		bad |= fval(r->rec, r->len, &L->fk_parent, &a);
		bad |= fval(r->rec, r->len, &L->fk_child, &b);
		break;
	default:
		bad |= fval(r->rec, r->len, &L->ex_pid, &a);
		break;
	}
	if (bad)
		return -1;
	o->a = (int)a;
	o->b = (int)b;
	o->c = (int)c;
	return 1;
}

struct evq {
	struct ev *v;
	size_t head, n, cap;
};

// append an event to a queue
static void evq_push(struct evq *q, const struct ev *e)
{
	if (q->head + q->n == q->cap) {
		if (q->head && q->head >= q->cap / 2) {
			memmove(q->v, q->v + q->head, q->n * sizeof *q->v);
			q->head = 0;
		} else {
			q->cap = q->cap ? q->cap * 2 : 1024;
			q->v = xrealloc(q->v, q->cap * sizeof *q->v);
		}
	}
	q->v[q->head + q->n++] = *e;
}

// table of /proc query functions
struct procops {
	void *ctx;
	int (*list_pids)(void *c, int **out);
	int (*list_tids)(void *c, int pid, int **out);
	int (*pid_ns)(void *c, int tid, u64 *ino);
	int (*nspid_last)(void *c, int tid, int *id);
	int (*ids)(void *c, int tid, int *ntgid, int *ntid);
	int (*attr)(void *c, int pid, char *buf, size_t n);
	int (*comm)(void *c, int tid, char *buf, size_t n);
	int (*pname)(void *c, int tid, char *buf, size_t n);
	int (*pid_ns_children)(void *c, int tid, u64 *ino);
};

struct namemap_ent {
	int key, used;
	char val[168];
};
struct namemap {
	struct namemap_ent *e;
	size_t cap, n;
};

static struct namemap_ent *nm_find(struct namemap *m, int key, int create);

// double the capacity of a name map and reinsert its entries
static void nm_grow(struct namemap *m)
{
	struct namemap old = *m;
	m->cap = old.cap ? old.cap * 2 : 64;
	m->e = xcalloc(m->cap, sizeof *m->e);
	m->n = 0;
	for (size_t i = 0; i < old.cap; i++)
		if (old.e[i].used) {
			struct namemap_ent *d = nm_find(m, old.e[i].key, 1);
			memcpy(d->val, old.e[i].val, sizeof d->val);
		}
	free(old.e);
}

// find the entry of a key in a name map, optionally creating it
static struct namemap_ent *nm_find(struct namemap *m, int key, int create)
{
	if (!m->cap || (create && (m->n + 1) * 2 > m->cap)) {
		if (!create && !m->cap)
			return NULL;
		nm_grow(m);
	}
	size_t i = ((u32)key * 2654435761u) & (m->cap - 1);
	for (;; i = (i + 1) & (m->cap - 1)) {
		struct namemap_ent *x = &m->e[i];
		if (!x->used) {
			if (!create)
				return NULL;
			x->used = 1;
			x->key = key;
			x->val[0] = 0;
			m->n++;
			return x;
		}
		if (x->key == key)
			return x;
	}
}

// check the entry for key against val
static int nm_same(struct namemap *m, int key, const char *val)
{
	struct namemap_ent *x = nm_find(m, key, 1);
	if (!strcmp(x->val, val))
		return 1;
	snprintf(x->val, sizeof x->val, "%s", val);
	return 0;
}

// return whether a name map holds a name for a key
static int nm_has(struct namemap *m, int key)
{
	struct namemap_ent *x = nm_find(m, key, 0);
	return x && x->val[0];
}

// clear the name of a key in a name map
static void nm_forget(struct namemap *m, int key)
{
	struct namemap_ent *x = nm_find(m, key, 0);
	if (x)
		x->val[0] = 0;
}

// free a name map
static void nm_clear(struct namemap *m)
{
	free(m->e);
	memset(m, 0, sizeof *m);
}

// connection to an Android peer
struct conn {
	int fd;
	int dead;
	char pkt[PKT_MAX];
	size_t pktlen;
	u8 *q;
	size_t qhead, qlen, qcap;
	struct namemap pm, tm;
};

// allocate a connection for a descriptor
static struct conn *conn_new(int fd)
{
	struct conn *c = xcalloc(1, sizeof *c);
	c->fd = fd;
	return c;
}

// close and free a connection
static void conn_free(struct conn *c)
{
	if (!c)
		return;
	if (c->fd >= 0)
		close(c->fd);
	nm_clear(&c->pm);
	nm_clear(&c->tm);
	free(c->q);
	free(c);
}

// copy the packet into the connection queue
static void conn_flushpkt(struct conn *c)
{
	if (!c->pktlen)
		return;
	size_t need = c->qlen + 2 + c->pktlen;
	if (need > CONN_QUEUE_MAX) {
		c->dead = 1;
		c->pktlen = 0;
		return;
	}
	if (c->qhead + need > c->qcap) {
		if (c->qhead) {
			memmove(c->q, c->q + c->qhead, c->qlen);
			c->qhead = 0;
		}
		if (need > c->qcap) {
			c->qcap = need * 2;
			c->q = xrealloc(c->q, c->qcap);
		}
	}
	u16 l = (u16)c->pktlen;
	memcpy(c->q + c->qhead + c->qlen, &l, 2);
	memcpy(c->q + c->qhead + c->qlen + 2, c->pkt, c->pktlen);
	c->qlen += 2 + c->pktlen;
	c->pktlen = 0;
}

// append a line to the connection's packet, flushing when full
static void conn_raw(struct conn *c, const char *line, size_t len)
{
	if (c->pktlen + len > PKT_MAX)
		conn_flushpkt(c);
	memcpy(c->pkt + c->pktlen, line, len);
	c->pktlen += len;
}

// format a line and append it to the connection's packet
static void conn_line(struct conn *c, const char *fmt, ...)
{
	char tmp[512];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
	va_end(ap);
	if (n <= 0 || (size_t)n >= sizeof tmp)
		return;
	conn_raw(c, tmp, (size_t)n);
}

// send the queued packets on the socket
static void conn_send(struct conn *c)
{
	conn_flushpkt(c);
	while (c->fd >= 0 && c->qlen && !c->dead) {
		u16 l;
		memcpy(&l, c->q + c->qhead, 2);
		ssize_t r = send(c->fd, c->q + c->qhead + 2, l, MSG_DONTWAIT | MSG_NOSIGNAL);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			if (errno != EAGAIN && errno != EWOULDBLOCK)
				c->dead = 1;
			return;
		}
		c->qhead += 2 + (size_t)l;
		c->qlen -= 2 + (size_t)l;
	}
	if (!c->qlen)
		c->qhead = 0;
}

struct sbx;

struct aproc {
	struct aproc *next;
	struct sbx *sb;
	int apid;
	char name[NAME_MAX_ANDROID + 1];
	u64 work_periods, host_delayed;
	u64 sent_wp, sent_hd;
	u64 last_c;
	int c_ever;
	int nthreads;
};

struct sbx {
	struct sbx *next;
	u64 ino;
	int alive, seen;
	int nthreads;
	struct aproc *procs;
	struct conn *conn;
};

struct nsv {
	struct nsv *next;
	u64 ino;
	int sandbox, seen;
};

enum tstate { ST_SLEEP, ST_RUNNABLE, ST_RUNNING };

struct task {
	struct task *hnext;
	int tid;
	int ns_known;
	u64 ino;
	struct sbx *sb;
	struct aproc *proc;
	int apid, atid;
	char comm[40];
	enum tstate state;
	int cpu;
	u64 last_ts;
	struct task *lnext, *lprev;
	int ep_open;
	u64 ep_start, ep_held, ep_gap, ep_last_held;
	u64 wp, wp_held;
	int wp_active;
};

struct engine {
	const struct procops *ops;
	int self_pid;
	u64 self_ino;
	int ncpu;
	int *occ;
	u8 *lossy;
	struct task **run;
	struct task **rl;
	struct task **tab;
	size_t ntasks;
	struct sbx *sbs;
	struct nsv *nsvs;
	u64 now, next_scan;
	int rescan_wanted;
	u64 events, lost_pages, lost_drops, late, malformed, unresolved, records, dropped_conns;
};

// initialize an engine with its process operations and CPU count
static void eng_init(struct engine *e, const struct procops *ops, int self_pid, int ncpu)
{
	memset(e, 0, sizeof *e);
	e->ops = ops;
	e->self_pid = self_pid;
	e->ncpu = ncpu;
	e->occ = xcalloc((size_t)ncpu, sizeof *e->occ);
	e->lossy = xcalloc((size_t)ncpu, sizeof *e->lossy);
	e->run = xcalloc((size_t)ncpu, sizeof *e->run);
	e->rl = xcalloc((size_t)ncpu, sizeof *e->rl);
	e->tab = xcalloc((size_t)1 << TASK_TAB_BITS, sizeof *e->tab);
	if (ops->pid_ns(ops->ctx, self_pid, &e->self_ino) < 0)
		e->self_ino = 0;
}

// return the hash slot of a task id
static size_t tab_slot(int tid) { return ((u32)tid * 2654435761u) >> (32 - TASK_TAB_BITS); }

// find a task by id
static struct task *task_find(struct engine *e, int tid)
{
	for (struct task *t = e->tab[tab_slot(tid)]; t; t = t->hnext)
		if (t->tid == tid)
			return t;
	return NULL;
}

// find a live sandbox by pid namespace inode
static struct sbx *sbx_find(struct engine *e, u64 ino)
{
	for (struct sbx *s = e->sbs; s; s = s->next)
		if (s->ino == ino && s->alive)
			return s;
	return NULL;
}

// find a namespace view by inode
static struct nsv *nsv_find(struct engine *e, u64 ino)
{
	for (struct nsv *v = e->nsvs; v; v = v->next)
		if (v->ino == ino)
			return v;
	return NULL;
}

// set the process name from argv0
static void load_pname(struct engine *e, int tid, struct aproc *p)
{
	char b[NAME_MAX_ANDROID + 1];
	if (e->ops->pname(e->ops->ctx, tid, b, sizeof b) == 0 && b[0]) {
		sanitize_name(b);
		snprintf(p->name, sizeof p->name, "%s", b);
	}
}

// set the thread name from its comm
static void load_comm(struct engine *e, struct task *t)
{
	char b[NAME_MAX_ANDROID + 1];
	if (e->ops->comm(e->ops->ctx, t->tid, b, 40) == 0 && b[0]) {
		sanitize_name(b);
		scopy(t->comm, sizeof t->comm, b);
	}
}

// find or create an Android process of a sandbox
static struct aproc *proc_get(struct engine *e, struct sbx *sb, int apid, int host_tid)
{
	for (struct aproc *p = sb->procs; p; p = p->next)
		if (p->apid == apid)
			return p;
	struct aproc *p = xcalloc(1, sizeof *p);
	p->sb = sb;
	p->apid = apid;
	snprintf(p->name, sizeof p->name, "_");
	load_pname(e, host_tid, p);
	p->next = sb->procs;
	sb->procs = p;
	return p;
}

// set the Android pid and tid
static int resolve_ids(struct engine *e, struct task *t)
{
	if (t->proc)
		return 0;
	int ntgid, ntid;
	if (!t->sb || e->ops->ids(e->ops->ctx, t->tid, &ntgid, &ntid) < 0)
		return -1;
	t->apid = ntgid;
	t->atid = ntid;
	t->proc = proc_get(e, t->sb, ntgid, t->tid);
	t->proc->nthreads++;
	snprintf(t->comm, sizeof t->comm, "_");
	load_comm(e, t);
	return 0;
}

// reload the command and process names of a task
static void refresh_names(struct engine *e, struct task *t)
{
	load_comm(e, t);
	if (t->proc)
		load_pname(e, t->tid, t->proc);
}

// attach a task to a sandbox and put it to sleep
static void attach_sandbox(struct engine *e, struct task *t, struct sbx *sb)
{
	t->sb = sb;
	t->state = ST_SLEEP;
	t->cpu = 0;
	sb->nthreads++;
	resolve_ids(e, t);
}

// set the sandbox of a thread
static void resolve_ns(struct engine *e, struct task *t)
{
	u64 ino;
	t->ns_known = 1;
	t->sb = NULL;
	if (e->ops->pid_ns(e->ops->ctx, t->tid, &ino) < 0)
		return;
	t->ino = ino;
	if (ino == e->self_ino)
		return;
	struct sbx *sb = sbx_find(e, ino);
	if (sb)
		attach_sandbox(e, t, sb);
	else if (!nsv_find(e, ino))
		e->rescan_wanted = 1;
}

// add a task to the task table
static struct task *task_new(struct engine *e, int tid)
{
	if (e->ntasks >= TASK_CAP) {
		for (size_t i = 0; i < ((size_t)1 << TASK_TAB_BITS); i++) {
			struct task **pp = &e->tab[i];
			while (*pp) {
				struct task *t = *pp;
				if (!t->sb) {
					*pp = t->hnext;
					free(t);
					e->ntasks--;
				} else {
					pp = &t->hnext;
				}
			}
		}
	}
	struct task *t = xcalloc(1, sizeof *t);
	t->tid = tid;
	size_t s = tab_slot(tid);
	t->hnext = e->tab[s];
	e->tab[s] = t;
	e->ntasks++;
	return t;
}

// find a task by id, creating it when missing
static struct task *get_task(struct engine *e, int tid)
{
	struct task *t = task_find(e, tid);
	if (!t)
		t = task_new(e, tid);
	if (!t->ns_known)
		resolve_ns(e, t);
	return t;
}

// add a task to the run list of a CPU
static void list_add(struct engine *e, int cpu, struct task *t)
{
	t->lprev = NULL;
	t->lnext = e->rl[cpu];
	if (e->rl[cpu])
		e->rl[cpu]->lprev = t;
	e->rl[cpu] = t;
}

// remove a task from its run list
static void list_del(struct engine *e, struct task *t)
{
	if (t->lprev)
		t->lprev->lnext = t->lnext;
	else
		e->rl[t->cpu] = t->lnext;
	if (t->lnext)
		t->lnext->lprev = t->lprev;
	t->lnext = t->lprev = NULL;
}

// send the process line to the connection
static void ensure_p(struct conn *c, struct aproc *p)
{
	char line[200];
	snprintf(line, sizeof line, "p %d %s\n", p->apid, p->name);
	if (!nm_same(&c->pm, p->apid, line))
		conn_raw(c, line, strlen(line));
}

// send the t line of a task
static void ensure_t(struct conn *c, struct task *t)
{
	char line[200];
	if (c->tm.n > 65536)
		nm_clear(&c->tm);
	snprintf(line, sizeof line, "t %d %d %s\n", t->apid, t->atid, t->comm);
	if (!nm_same(&c->tm, t->atid, line))
		conn_raw(c, line, strlen(line));
}

// return whether a process has counts not yet sent
static int proc_dirty(const struct aproc *p)
{
	return p->work_periods != p->sent_wp || p->host_delayed != p->sent_hd;
}

// send the process counts to the connection
static void emit_c(struct engine *e, struct aproc *p)
{
	struct conn *c = p->sb->conn;
	p->sent_wp = p->work_periods;
	p->sent_hd = p->host_delayed;
	p->last_c = e->now;
	p->c_ever = 1;
	if (!c)
		return;
	ensure_p(c, p);
	conn_line(c, "c %d %llu %llu\n", p->apid, (unsigned long long)p->work_periods,
		  (unsigned long long)p->host_delayed);
}

// send the final counts of an exiting process and forget it
static void proc_exit(struct engine *e, struct aproc *p)
{
	struct conn *c = p->sb->conn;
	if (c) {
		if (proc_dirty(p))
			emit_c(e, p);
		if (nm_has(&c->pm, p->apid)) {
			conn_line(c, "x %d\n", p->apid);
			nm_forget(&c->pm, p->apid);
		}
	}
	struct aproc **pp = &p->sb->procs;
	while (*pp != p)
		pp = &(*pp)->next;
	*pp = p->next;
	free(p);
}

// send the d line for a record
static void emit_record(struct engine *e, struct task *t, u64 start, u64 end, u64 held)
{
	t->wp_held += held / 1000;
	e->records++;
	struct conn *c = t->sb->conn;
	if (resolve_ids(e, t) < 0) {
		e->unresolved++;
		return;
	}
	if (!c)
		return;
	refresh_names(e, t);
	ensure_p(c, t->proc);
	ensure_t(c, t);
	conn_line(c, "d %d %d %llu %llu %llu %llu\n", t->apid, t->atid, (unsigned long long)start,
		  (unsigned long long)end, (unsigned long long)held, (unsigned long long)t->wp);
}

// close the open episode of a task at a time
static void close_ep(struct engine *e, struct task *t, u64 end)
{
	if (!t->ep_open)
		return;
	t->ep_open = 0;
	if (t->ep_held >= FLOOR_NS)
		emit_record(e, t, t->ep_start, end, t->ep_held);
}

// start a work period of a task
static void start_wp(struct engine *e, struct task *t)
{
	t->wp++;
	t->wp_held = 0;
	t->wp_active = 1;
	resolve_ids(e, t);
}

// end the active work period of a task
static void end_wp(struct engine *e, struct task *t)
{
	if (!t->wp_active)
		return;
	t->wp_active = 0;
	if (resolve_ids(e, t) < 0)
		return;
	t->proc->work_periods++;
	if (t->wp_held >= DELAYED_WP_US)
		t->proc->host_delayed++;
}

// update the episode of a thread
static void apply(struct engine *e, struct task *t, u64 a, u64 b, int held)
{
	while (a < b) {
		if (held) {
			if (!t->ep_open) {
				t->ep_open = 1;
				t->ep_start = a;
				t->ep_held = 0;
				t->ep_gap = 0;
			}
			u64 lim = t->ep_start + MAX_SPAN_NS;
			u64 seg = b < lim ? b : lim;
			t->ep_held += seg - a;
			t->ep_gap = 0;
			t->ep_last_held = seg;
			a = seg;
			if (seg == lim)
				close_ep(e, t, lim);
		} else {
			if (!t->ep_open)
				return;
			u64 lim = t->ep_start + MAX_SPAN_NS;
			u64 gap_end = a + (GAP_NS - t->ep_gap);
			if (gap_end <= b && gap_end <= lim)
				close_ep(e, t, t->ep_last_held);
			else if (lim <= b)
				close_ep(e, t, lim);
			else
				t->ep_gap += b - a;
			return;
		}
	}
}

// compare the sandboxes of two tasks
static int is_held(struct engine *e, const struct task *t, int occ_tid)
{
	if (occ_tid == 0)
		return 0;
	return get_task(e, occ_tid)->sb != t->sb;
}

// apply the elapsed time to a task
static void settle(struct engine *e, struct task *t, u64 now)
{
	if (now <= t->last_ts)
		return;
	if (t->state == ST_RUNNABLE) {
		if (!e->lossy[t->cpu])
			apply(e, t, t->last_ts, now, is_held(e, t, e->occ[t->cpu]));
	} else if (t->state == ST_RUNNING) {
		apply(e, t, t->last_ts, now, 0);
	}
	t->last_ts = now;
}

// settle all of the tasks on the run lists at a time
static void scan_active(struct engine *e, u64 now)
{
	for (int c = 0; c < e->ncpu; c++) {
		for (struct task *t = e->rl[c]; t; t = t->lnext)
			settle(e, t, now);
		if (e->run[c])
			settle(e, e->run[c], now);
	}
}

// update the held state of tasks on a CPU when its occupant changes
static void occ_change(struct engine *e, int cpu, int next, u64 ts)
{
	if (e->occ[cpu] != next)
		for (struct task *t = e->rl[cpu]; t; t = t->lnext)
			if (is_held(e, t, e->occ[cpu]) != is_held(e, t, next))
				settle(e, t, ts);
	e->occ[cpu] = next;
}

// remove a task from its cpu
static void leave_cpu(struct engine *e, struct task *t, u64 ts)
{
	settle(e, t, ts);
	if (t->state == ST_RUNNABLE)
		list_del(e, t);
	else if (e->run[t->cpu] == t)
		e->run[t->cpu] = NULL;
}

// move a runnable thread to another cpu's list
static void move_runnable(struct engine *e, struct task *t, int cpu)
{
	list_del(e, t);
	t->cpu = cpu;
	list_add(e, cpu, t);
}

// switch a task out of a cpu
static void switch_out(struct engine *e, struct task *p, int cpu, int runnable, u64 ts)
{
	if (p->state == ST_SLEEP)
		start_wp(e, p);
	else
		leave_cpu(e, p, ts);
	p->last_ts = ts;
	if (runnable) {
		p->state = ST_RUNNABLE;
		p->cpu = cpu;
		list_add(e, cpu, p);
	} else {
		close_ep(e, p, p->ep_last_held);
		end_wp(e, p);
		p->state = ST_SLEEP;
	}
}

// switch a task in on a CPU
static void switch_in(struct engine *e, struct task *n, int cpu, u64 ts)
{
	if (n->state == ST_SLEEP)
		start_wp(e, n);
	else
		leave_cpu(e, n, ts);
	n->state = ST_RUNNING;
	n->cpu = cpu;
	n->last_ts = ts;
	e->run[cpu] = n;
}

// update tasks for a sched_switch event
static void on_switch(struct engine *e, const struct ev *v)
{
	int cpu = v->cpu;
	if (cpu >= e->ncpu)
		return;
	occ_change(e, cpu, v->b, v->ts);
	e->lossy[cpu] = 0;
	if (e->run[cpu] && e->run[cpu]->tid != v->a)
		e->run[cpu] = NULL;
	if (v->a != 0) {
		struct task *p = get_task(e, v->a);
		if (p->sb)
			switch_out(e, p, cpu, v->c, v->ts);
	}
	if (v->b != 0) {
		struct task *n = get_task(e, v->b);
		if (n->sb)
			switch_in(e, n, cpu, v->ts);
	}
}

// handle a wake event
static void on_wake(struct engine *e, const struct ev *v)
{
	if (v->b < 0 || v->b >= e->ncpu)
		return;
	struct task *t = get_task(e, v->a);
	if (!t->sb)
		return;
	if (t->state == ST_SLEEP) {
		start_wp(e, t);
		t->state = ST_RUNNABLE;
		t->cpu = v->b;
		t->last_ts = v->ts;
		list_add(e, v->b, t);
	} else if (t->state == ST_RUNNABLE && v->kind != K_WAKING && t->cpu != v->b) {
		settle(e, t, v->ts);
		move_runnable(e, t, v->b);
	}
}

// handle a migrate event
static void on_migrate(struct engine *e, const struct ev *v)
{
	int dest = v->c;
	if (dest < 0 || dest >= e->ncpu)
		return;
	struct task *t = task_find(e, v->a);
	if (!t || !t->sb || t->state != ST_RUNNABLE || t->cpu == dest)
		return;
	settle(e, t, v->ts);
	move_runnable(e, t, dest);
}

// forget a task and release what it holds
static void drop_task(struct engine *e, struct task *t, u64 ts)
{
	if (t->sb) {
		if (t->state != ST_SLEEP)
			leave_cpu(e, t, ts);
		close_ep(e, t, t->ep_last_held);
		end_wp(e, t);
		t->sb->nthreads--;
		if (t->proc && --t->proc->nthreads <= 0)
			proc_exit(e, t->proc);
	}
	struct task **pp = &e->tab[tab_slot(t->tid)];
	while (*pp != t)
		pp = &(*pp)->hnext;
	*pp = t->hnext;
	free(t);
	e->ntasks--;
}

// add the child task of a fork
static void on_fork(struct engine *e, const struct ev *v)
{
	struct task *parent = get_task(e, v->a);
	struct sbx *psb = parent->sb;
	u64 pino = parent->ino;
	struct task *old = task_find(e, v->b);
	if (old)
		drop_task(e, old, v->ts);
	struct task *child = task_new(e, v->b);
	u64 ino;
	if (psb) {
		child->ns_known = 1;
		child->ino = pino;
		attach_sandbox(e, child, psb);
	} else if (e->ops->pid_ns(e->ops->ctx, v->b, &ino) == 0) {
		resolve_ns(e, child);
	} else if (e->ops->pid_ns_children(e->ops->ctx, v->a, &ino) == 0 && ino != e->self_ino &&
		   sbx_find(e, ino)) {
		child->ns_known = 1;
		child->ino = ino;
		attach_sandbox(e, child, sbx_find(e, ino));
	}
}

// handle a task exit event
static void on_task_exit(struct engine *e, const struct ev *v)
{
	struct task *t = task_find(e, v->a);
	if (t)
		drop_task(e, t, v->ts);
}

// close the open episodes of a cpu
static void on_loss(struct engine *e, const struct ev *v)
{
	int cpu = v->cpu;
	if (cpu >= e->ncpu)
		return;
	e->lost_pages++;
	for (struct task *t = e->rl[cpu]; t; t = t->lnext) {
		close_ep(e, t, t->ep_last_held);
		t->last_ts = v->ts;
	}
	if (e->run[cpu]) {
		close_ep(e, e->run[cpu], e->run[cpu]->ep_last_held);
		e->run[cpu]->last_ts = v->ts;
	}
	e->occ[cpu] = 0;
	e->lossy[cpu] = 1;
}

// apply an event to the engine
static void eng_event(struct engine *e, const struct ev *in)
{
	struct ev v = *in;
	if (v.ts < e->now) {
		v.ts = e->now;
		e->late++;
	}
	e->now = v.ts;
	e->events++;
	if (v.ts >= e->next_scan) {
		scan_active(e, v.ts);
		e->next_scan = v.ts + SPAN_SCAN_NS;
	}
	switch (v.kind) {
	case K_SWITCH: on_switch(e, &v); break;
	case K_WAKING: case K_WAKEUP: case K_WAKEUP_NEW: on_wake(e, &v); break;
	case K_MIGRATE: on_migrate(e, &v); break;
	case K_FORK: on_fork(e, &v); break;
	case K_EXIT: on_task_exit(e, &v); break;
	case K_LOSS: on_loss(e, &v); break;
	default: break;
	}
}

// send the due c lines
static void eng_tick(struct engine *e, u64 now)
{
	if (now > e->now)
		e->now = now;
	scan_active(e, e->now);
	for (struct sbx *s = e->sbs; s; s = s->next) {
		if (!s->alive)
			continue;
		for (struct aproc *p = s->procs; p; p = p->next)
			if (proc_dirty(p) && (!p->c_ever || e->now - p->last_c >= C_INTERVAL_NS))
				emit_c(e, p);
		if (s->conn)
			conn_flushpkt(s->conn);
	}
}

// set the connection of a sandbox
static void eng_connect(struct engine *e, struct sbx *sb, struct conn *c)
{
	if (sb->conn)
		conn_free(sb->conn);
	sb->conn = c;
	for (struct aproc *p = sb->procs; p; p = p->next)
		if (p->work_periods > 0) {
			ensure_p(c, p);
			emit_c(e, p);
		}
}

// allocate a sandbox for a namespace inode
static struct sbx *sbx_new(struct engine *e, u64 ino)
{
	struct sbx *s = xcalloc(1, sizeof *s);
	s->ino = ino;
	s->alive = 1;
	s->seen = 1;
	s->next = e->sbs;
	e->sbs = s;
	return s;
}

// scan /proc for sandbox namespaces
static void eng_rescan(struct engine *e)
{
	const struct procops *o = e->ops;
	int *pids = NULL;
	int n = o->list_pids(o->ctx, &pids);
	if (n < 0)
		return;
	u64 *inos = xcalloc((size_t)n, sizeof *inos);
	struct sbx **added = xcalloc((size_t)n, sizeof *added);
	int nadded = 0;
	for (struct nsv *v = e->nsvs; v; v = v->next)
		v->seen = 0;
	for (struct sbx *s = e->sbs; s; s = s->next)
		s->seen = 0;
	for (int i = 0; i < n; i++) {
		u64 ino;
		if (o->pid_ns(o->ctx, pids[i], &ino) < 0 || ino == e->self_ino)
			continue;
		inos[i] = ino;
		struct nsv *v = nsv_find(e, ino);
		if (v) {
			v->seen = 1;
			if (v->sandbox) {
				struct sbx *s = sbx_find(e, ino);
				if (s)
					s->seen = 1;
			}
			continue;
		}
		int id;
		if (o->nspid_last(o->ctx, pids[i], &id) < 0 || id != 1)
			continue;
		char a[64];
		v = xcalloc(1, sizeof *v);
		v->ino = ino;
		v->seen = 1;
		v->sandbox = o->attr(o->ctx, pids[i], a, sizeof a) == 0 && !strcmp(a, INIT_CTX);
		v->next = e->nsvs;
		e->nsvs = v;
		if (v->sandbox)
			added[nadded++] = sbx_new(e, ino);
	}
	struct nsv **vp = &e->nsvs;
	while (*vp) {
		if (!(*vp)->seen) {
			struct nsv *d = *vp;
			*vp = d->next;
			free(d);
		} else {
			vp = &(*vp)->next;
		}
	}
	for (struct sbx *s = e->sbs; s; s = s->next)
		if (s->alive && !s->seen) {
			s->alive = 0;
			conn_free(s->conn);
			s->conn = NULL;
		}
	for (int f = 0; f < nadded; f++) {
		struct sbx *s = added[f];
		for (size_t i = 0; i < ((size_t)1 << TASK_TAB_BITS); i++)
			for (struct task *t = e->tab[i]; t; t = t->hnext)
				if (t->ns_known && !t->sb && t->ino == s->ino)
					attach_sandbox(e, t, s);
		for (int i = 0; i < n; i++) {
			if (inos[i] != s->ino)
				continue;
			int *tids = NULL;
			int nt = o->list_tids(o->ctx, pids[i], &tids);
			for (int j = 0; j < nt; j++) {
				struct task *t = task_find(e, tids[j]);
				if (t && t->sb)
					continue;
				if (!t)
					t = task_new(e, tids[j]);
				t->ns_known = 1;
				t->ino = s->ino;
				attach_sandbox(e, t, s);
			}
			free(tids);
		}
	}
	e->rescan_wanted = 0;
	free(pids);
	free(inos);
	free(added);
}

// return the sandbox of a peer
static struct sbx *peer_sandbox(struct engine *e, int pid)
{
	char a[64];
	u64 ino;
	if (e->ops->attr(e->ops->ctx, pid, a, sizeof a) < 0 || strcmp(a, HOST_DELAY_CTX))
		return NULL;
	if (e->ops->pid_ns(e->ops->ctx, pid, &ino) < 0)
		return NULL;
	struct sbx *sb = sbx_find(e, ino);
	if (!sb) {
		eng_rescan(e);
		sb = sbx_find(e, ino);
	}
	return sb;
}

// format the engine and decoder statistics as JSON
static int status_build(const struct engine *e, const struct decode_stats *ds, int nconn, char *buf, size_t cap)
{
	size_t n = (size_t)snprintf(buf, cap,
		"{\"events\":%llu,\"lost_pages\":%llu,\"lost_drops\":%llu,\"late\":%llu,\"malformed\":%llu,"
		"\"unresolved\":%llu,\"records\":%llu,\"connections\":%d,\"cpus\":%d,\"namespaces\":[",
		(unsigned long long)e->events, (unsigned long long)e->lost_pages,
		(unsigned long long)e->lost_drops, (unsigned long long)e->late,
		(unsigned long long)(e->malformed + (ds ? ds->malformed : 0)),
		(unsigned long long)e->unresolved, (unsigned long long)e->records, nconn, e->ncpu);
	int first = 1;
	for (const struct sbx *s = e->sbs; s && n < cap; s = s->next) {
		if (!s->alive)
			continue;
		int np = 0;
		for (const struct aproc *p = s->procs; p; p = p->next)
			np++;
		n += (size_t)snprintf(buf + n, cap - n, "%s{\"ns\":%llu,\"threads\":%d,\"processes\":%d,\"connected\":%d}",
				      first ? "" : ",", (unsigned long long)s->ino, s->nthreads, np, s->conn ? 1 : 0);
		first = 0;
	}
	if (n < cap)
		n += (size_t)snprintf(buf + n, cap - n, "]}\n");
	return n < cap ? (int)n : -1;
}

// run the queued events in timestamp order
static u64 merge_run(struct engine *e, struct evq *q, int ncpu, u64 wm)
{
	u64 done = 0;
	for (;;) {
		int best = -1;
		u64 bt = 0;
		for (int c = 0; c < ncpu; c++) {
			if (!q[c].n)
				continue;
			u64 t = q[c].v[q[c].head].ts;
			if (t <= wm && (best < 0 || t < bt)) {
				best = c;
				bt = t;
			}
		}
		if (best < 0)
			return done;
		eng_event(e, &q[best].v[q[best].head]);
		q[best].head++;
		q[best].n--;
		if (!q[best].n)
			q[best].head = 0;
		done++;
	}
}

// return now minus the watermark, or 0 when now is smaller
static u64 watermark(u64 now) { return now > WATERMARK_NS ? now - WATERMARK_NS : 0; }

// read a file of a process under /proc into a buffer
static int proc_read(int id, const char *leaf, char *buf, size_t cap)
{
	char path[64];
	snprintf(path, sizeof path, "/proc/%d/%s", id, leaf);
	return read_text(path, buf, cap);
}

// list the numeric names in a directory
static int real_list_ids(const char *dir, int **out)
{
	DIR *d = opendir(dir);
	if (!d)
		return -1;
	size_t cap = 256, n = 0;
	int *v = xcalloc(cap, sizeof *v);
	struct dirent *de;
	while ((de = readdir(d))) {
		if (de->d_name[0] < '1' || de->d_name[0] > '9')
			continue;
		if (n == cap) {
			cap *= 2;
			v = xrealloc(v, cap * sizeof *v);
		}
		v[n++] = atoi(de->d_name);
	}
	closedir(d);
	*out = v;
	return (int)n;
}

// list the process ids from /proc
static int real_list_pids(void *c, int **out)
{
	(void)c;
	return real_list_ids("/proc", out);
}

// list the thread ids of a process
static int real_list_tids(void *c, int pid, int **out)
{
	(void)c;
	char dir[64];
	snprintf(dir, sizeof dir, "/proc/%d/task", pid);
	return real_list_ids(dir, out);
}

// read the inode of /proc/<tid>/ns/<leaf>
static int read_pid_ns(int tid, const char *leaf, u64 *ino)
{
	char path[80], link[64];
	snprintf(path, sizeof path, "/proc/%d/ns/%s", tid, leaf);
	ssize_t n = readlink(path, link, sizeof link - 1);
	if (n < 0)
		return -1;
	link[n] = 0;
	unsigned long long v;
	if (sscanf(link, "pid:[%llu]", &v) != 1)
		return -1;
	*ino = v;
	return 0;
}

// read the pid namespace inode of a thread
static int real_pid_ns(void *c, int tid, u64 *ino)
{
	(void)c;
	return read_pid_ns(tid, "pid", ino);
}

// get the last integer of a status line
static int status_last(const char *text, const char *key, int *out)
{
	size_t kl = strlen(key);
	for (const char *p = text; p; p = strchr(p, '\n'), p = p ? p + 1 : NULL) {
		if (strncmp(p, key, kl))
			continue;
		const char *e = strchr(p, '\n');
		if (!e)
			e = p + strlen(p);
		const char *q = e;
		while (q > p + kl && (q[-1] == ' ' || q[-1] == '\t'))
			q--;
		const char *b = q;
		while (b > p + kl && isdigit((unsigned char)b[-1]))
			b--;
		if (b == q)
			return -1;
		*out = atoi(b);
		return 0;
	}
	return -1;
}

// read the pid_for_children inode of tid
static int real_pid_ns_children(void *c, int tid, u64 *ino)
{
	(void)c;
	return read_pid_ns(tid, "pid_for_children", ino);
}

// read the last namespace thread id of a thread from its status
static int real_nspid_last(void *c, int tid, int *id)
{
	(void)c;
	char buf[4096];
	if (proc_read(tid, "status", buf, sizeof buf) < 0)
		return -1;
	return status_last(buf, "NSpid:", id);
}

// read the namespace thread group id and thread id of a thread
static int real_ids(void *c, int tid, int *ntgid, int *ntid)
{
	(void)c;
	char buf[4096];
	if (proc_read(tid, "status", buf, sizeof buf) < 0)
		return -1;
	if (status_last(buf, "NStgid:", ntgid) || status_last(buf, "NSpid:", ntid))
		return -1;
	return 0;
}

// read the security context of a process
static int real_attr(void *c, int pid, char *buf, size_t n)
{
	(void)c;
	if (proc_read(pid, "attr/current", buf, n) < 0)
		return -1;
	size_t l = strlen(buf);
	while (l && (buf[l - 1] == '\n' || buf[l - 1] == ' '))
		buf[--l] = 0;
	return 0;
}

// read the command name of a thread
static int real_comm(void *c, int tid, char *buf, size_t n)
{
	(void)c;
	if (proc_read(tid, "comm", buf, n) < 0)
		return -1;
	size_t l = strlen(buf);
	while (l && buf[l - 1] == '\n')
		buf[--l] = 0;
	return 0;
}

// read the process name of a thread
static int real_pname(void *c, int tid, char *buf, size_t n)
{
	if (proc_read(tid, "cmdline", buf, n) > 0 && buf[0])
		return 0;
	return real_comm(c, tid, buf, n);
}

static const struct procops REAL_OPS = {
	NULL, real_list_pids, real_list_tids, real_pid_ns, real_nspid_last, real_ids, real_attr, real_comm,
	real_pname, real_pid_ns_children,
};

struct inst {
	char dir[512];
	int ncpu;
	int *fd;
	u64 *drop_prev;
	struct layout L;
};

// stat the instances directory of root
static int has_instances_dir(const char *root)
{
	char p[512];
	struct stat st;
	snprintf(p, sizeof p, "%s/instances", root);
	return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

// return the tracefs root
static const char *tracefs_root(const char *want)
{
	static const char *const cands[] = { "/sys/kernel/tracing", "/sys/kernel/debug/tracing" };
	if (want)
		return has_instances_dir(want) ? want : NULL;
	for (size_t i = 0; i < 2; i++)
		if (has_instances_dir(cands[i]))
			return cands[i];
	return NULL;
}

// write a value to a file of the trace instance
static int inst_write(const struct inst *in, const char *leaf, const char *val)
{
	char p[640];
	snprintf(p, sizeof p, "%s/%s", in->dir, leaf);
	if (write_text(p, val)) {
		logmsg("write %s=%s: %s", p, val, strerror(errno));
		return -1;
	}
	return 0;
}

// close the instance's descriptors and free its state
static void inst_teardown(struct inst *in)
{
	for (int i = 0; i < in->ncpu; i++)
		if (in->fd && in->fd[i] >= 0)
			close(in->fd[i]);
	in->ncpu = 0;
	free(in->fd);
	free(in->drop_prev);
	in->fd = NULL;
	in->drop_prev = NULL;
	if (in->dir[0] && rmdir(in->dir) && errno != ENOENT)
		logmsg("rmdir %s: %s", in->dir, strerror(errno));
}

// create the tracefs instance
static int inst_setup(struct inst *in, const char *root, const char *name, int buffer_kb)
{
	memset(in, 0, sizeof *in);
	snprintf(in->dir, sizeof in->dir, "%s/instances/%s", root, name);
	if (rmdir(in->dir) && errno != ENOENT)
		logmsg("leftover instance %s not removable: %s", in->dir, strerror(errno));
	if (mkdir(in->dir, 0755)) {
		logmsg("mkdir %s: %s", in->dir, strerror(errno));
		in->dir[0] = 0;
		return -1;
	}
	char v[32];
	snprintf(v, sizeof v, "%d", buffer_kb);
	if (inst_write(in, "buffer_size_kb", v) || inst_write(in, "trace_clock", "boot") ||
	    inst_write(in, "options/overwrite", "0"))
		goto fail;
	static char hp[16384], he[16384], ft[N_EV][16384];
	char p[640];
	const char *fp[N_EV];
	snprintf(p, sizeof p, "%s/events/header_page", in->dir);
	int r1 = read_text(p, hp, sizeof hp);
	snprintf(p, sizeof p, "%s/events/header_event", in->dir);
	int r2 = read_text(p, he, sizeof he);
	if (r1 < 0 || r2 < 0) {
		logmsg("cannot read header_page/header_event under %s", in->dir);
		goto fail;
	}
	for (int i = 0; i < N_EV; i++) {
		snprintf(p, sizeof p, "%s/events/sched/%s/format", in->dir, EV_NAMES[i]);
		if (read_text(p, ft[i], sizeof ft[i]) < 0) {
			logmsg("cannot read %s: %s", p, strerror(errno));
			goto fail;
		}
		fp[i] = ft[i];
	}
	if (layout_build(&in->L, hp, he, fp))
		goto fail;
	if (in->L.fmt_default)
		logmsg("sched_switch print fmt not understood; using prev_state mask 0xff and preempt flag 0x100");
	for (int i = 0; i < N_EV; i++) {
		char leaf[96];
		snprintf(leaf, sizeof leaf, "events/sched/%s/enable", EV_NAMES[i]);
		if (inst_write(in, leaf, "1"))
			goto fail;
	}
	snprintf(p, sizeof p, "%s/per_cpu", in->dir);
	DIR *d = opendir(p);
	if (!d) {
		logmsg("opendir %s: %s", p, strerror(errno));
		goto fail;
	}
	struct dirent *de;
	int max = -1;
	while ((de = readdir(d)))
		if (!strncmp(de->d_name, "cpu", 3) && isdigit((unsigned char)de->d_name[3]) && atoi(de->d_name + 3) > max)
			max = atoi(de->d_name + 3);
	closedir(d);
	if (max < 0)
		goto fail;
	in->ncpu = max + 1;
	in->fd = xcalloc((size_t)in->ncpu, sizeof *in->fd);
	in->drop_prev = xcalloc((size_t)in->ncpu, sizeof *in->drop_prev);
	for (int i = 0; i < in->ncpu; i++) {
		snprintf(p, sizeof p, "%s/per_cpu/cpu%d/trace_pipe_raw", in->dir, i);
		in->fd[i] = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (in->fd[i] < 0)
			logmsg("open %s: %s", p, strerror(errno));
	}
	if (inst_write(in, "tracing_on", "1"))
		goto fail;
	return 0;
fail:
	inst_teardown(in);
	return -1;
}

// sum the dropped event counters of a cpu
static u64 inst_drops(const struct inst *in, int cpu)
{
	char p[640], buf[2048];
	snprintf(p, sizeof p, "%s/per_cpu/cpu%d/stats", in->dir, cpu);
	if (read_text(p, buf, sizeof buf) < 0)
		return 0;
	u64 sum = 0;
	static const char *const keys[] = { "overrun:", "commit overrun:", "dropped events:" };
	for (const char *l = buf; l && *l; l = strchr(l, '\n'), l = l ? l + 1 : NULL)
		for (size_t k = 0; k < 3; k++)
			if (!strncmp(l, keys[k], strlen(keys[k])))
				sum += strtoull(l + strlen(keys[k]), NULL, 10);
	return sum;
}

struct cbctx {
	const struct layout *L;
	struct evq *q;
	u64 bad;
};

// decode a raw event and queue it
static void queue_cb(void *ctx, const struct rawev *r)
{
	struct cbctx *c = ctx;
	struct ev ev;
	if (r->id == -1) {
		memset(&ev, 0, sizeof ev);
		ev.ts = r->ts;
		ev.cpu = (u16)r->cpu;
		ev.kind = K_LOSS;
		evq_push(c->q, &ev);
		return;
	}
	int k = raw_to_ev(c->L, r, &ev);
	if (k > 0)
		evq_push(c->q, &ev);
	else if (k < 0)
		c->bad++;
}

// read a cpu's trace pipe into its queue
static int read_cpu(const struct inst *in, int cpu, struct evq *q, u8 *page, struct decode_stats *ds, u64 *bad)
{
	struct cbctx cb = { &in->L, q, 0 };
	size_t psz = (size_t)in->L.pg.page_size;
	int capped = 0;
	while (in->fd[cpu] >= 0) {
		if (q->n >= QUEUE_CAP_EVENTS) {
			capped = 1;
			break;
		}
		ssize_t n = read(in->fd[cpu], page, psz);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		decode_page(&in->L.pg, cpu, page, (size_t)n, queue_cb, &cb, ds);
	}
	*bad += cb.bad;
	return capped;
}

static const char *g_selinuxfs = "/sys/fs/selinux";
static const char *g_attr_current = "/proc/self/attr/current";

// read the recorded SELinux mode
static int selinux_namespace_mode(void)
{
	const char *path = getenv("RHIZO_SELINUX_MODE_FILE");
	if (!path)
		path = "/run/rhizo-selinux-mode";
	char buf[32] = "";
	FILE *f = fopen(path, "re");
	if (!f) {
		logmsg("RHIZO_MARKER delayd_domain failed reason=selinux-mode mode-file=%s errno=%d", path, errno);
		return -1;
	}
	size_t n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	buf[n] = 0;
	while (n && buf[n - 1] == '\n')
		buf[--n] = 0;
	if (!strcmp(buf, "namespace"))
		return 1;
	if (!strcmp(buf, "host"))
		return 0;
	logmsg("RHIZO_MARKER delayd_domain failed reason=selinux-mode mode-file=%s value='%s'", path, buf);
	return -1;
}

// exec this program in DELAYD_CTX
static void enter_domain(char **argv, int cleanup)
{
	struct stat st;
	int ns = selinux_namespace_mode();
	if (ns < 0 && cleanup) {
		logmsg("RHIZO_MARKER delayd_domain state=mode-unreadable cleanup=current-domain");
		return;
	}
	if (ns < 0)
		exit(SELINUX_MODE_EXIT);
	if (ns) {
		logmsg("RHIZO_MARKER delayd_domain state=no-selinux mode=namespace want=%s", DELAYD_CTX);
		return;
	}
	if (stat(g_selinuxfs, &st) && errno == ENOENT) {
		logmsg("RHIZO_MARKER delayd_domain state=no-selinux want=%s", DELAYD_CTX);
		return;
	}
	char cur[128];
	if (read_text(g_attr_current, cur, sizeof cur) < 0)
		cur[0] = 0;
	size_t l = strlen(cur);
	while (l && (cur[l - 1] == '\n' || cur[l - 1] == ' '))
		cur[--l] = 0;
	if (!strcmp(cur, DELAYD_CTX)) {
		unsetenv(ENTERING_ENV);
		logmsg("RHIZO_MARKER delayd_domain entered=%s", DELAYD_CTX);
		return;
	}
	if (!strcmp(cur, "kernel")) {
		logmsg("RHIZO_MARKER delayd_domain state=deferred current=%s want=%s", cur, DELAYD_CTX);
		return;
	}
	if (!strcmp(cur, "u:r:kernel:s0") || getenv(ENTERING_ENV)) {
		logmsg("RHIZO_MARKER delayd_domain failed reason=%s current=%s want=%s",
		       getenv(ENTERING_ENV) ? "domain-refused" : "domain-kernel", cur, DELAYD_CTX);
		exit(1);
	}
	if (write_text("/proc/self/attr/exec", DELAYD_CTX)) {
		logmsg("RHIZO_MARKER delayd_domain failed reason=attr-exec errno=%d current=%s", errno, cur);
		exit(1);
	}
	setenv(ENTERING_ENV, "1", 1);
	char exe[512];
	ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	if (n < 0) {
		logmsg("readlink /proc/self/exe: %s", strerror(errno));
		exit(1);
	}
	exe[n] = 0;
	execv(exe, argv);
	logmsg("exec %s: %s", exe, strerror(errno));
	exit(1);
}

// send READY=1 to systemd
static void sd_notify_ready(void)
{
	const char *path = getenv("NOTIFY_SOCKET");
	if (!path || !*path)
		return;
	struct sockaddr_un a;
	memset(&a, 0, sizeof a);
	a.sun_family = AF_UNIX;
	size_t l = strlen(path);
	if (l >= sizeof a.sun_path)
		return;
	memcpy(a.sun_path, path, l);
	if (path[0] == '@')
		a.sun_path[0] = 0;
	int s = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (s < 0)
		return;
	if (sendto(s, "READY=1", 7, 0, (struct sockaddr *)&a, (socklen_t)(offsetof(struct sockaddr_un, sun_path) + l)) < 0)
		logmsg("could not tell systemd it is ready: %s", strerror(errno));
	close(s);
}

// write the status text to a file
static int write_status_atomic(const char *path, const char *text)
{
	char tmp[600];
	snprintf(tmp, sizeof tmp, "%s.tmp", path);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		return -1;
	size_t n = strlen(text);
	ssize_t w = write(fd, text, n);
	close(fd);
	if (w != (ssize_t)n || rename(tmp, path)) {
		unlink(tmp);
		return -1;
	}
	return 0;
}

static volatile sig_atomic_t g_stop;
// set the stop flag
static void on_signal(int sig) { (void)sig; g_stop = 1; }

struct cfg {
	const char *socket_path, *status_path, *tracefs, *instance;
	int buffer_kb;
	int dump_secs;
	int selftest;
	int remove_instance;
};

// create, bind and listen on the daemon socket
static int listen_socket(const char *path)
{
	struct sockaddr_un a;
	memset(&a, 0, sizeof a);
	a.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof a.sun_path) {
		logmsg("socket path too long");
		return -1;
	}
	strcpy(a.sun_path, path);
	int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (s < 0)
		return -1;
	unlink(path);
	if (bind(s, (struct sockaddr *)&a, sizeof a) || chmod(path, 0666) || listen(s, 8)) {
		logmsg("socket %s: %s", path, strerror(errno));
		close(s);
		return -1;
	}
	return s;
}

// accept pending connections and add them to the engine
static void accept_new(struct engine *e, int lfd)
{
	for (;;) {
		int fd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
		if (fd < 0)
			return;
		struct ucred cr;
		socklen_t l = sizeof cr;
		struct sbx *sb = NULL;
		if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &l) == 0 && cr.pid > 0)
			sb = peer_sandbox(e, cr.pid);
		if (!sb) {
			close(fd);
			continue;
		}
		eng_connect(e, sb, conn_new(fd));
	}
}

// send queued packets to each peer
static int service_conns(struct engine *e)
{
	int n = 0;
	for (struct sbx *s = e->sbs; s; s = s->next) {
		struct conn *c = s->conn;
		if (!c)
			continue;
		char sink[256];
		ssize_t r = recv(c->fd, sink, sizeof sink, MSG_DONTWAIT);
		if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
			c->dead = 1;
		else
			conn_send(c);
		if (c->dead) {
			conn_free(c);
			s->conn = NULL;
			e->dropped_conns++;
		} else {
			n++;
		}
	}
	return n;
}

// remove the tracefs instance
static int run_remove_instance(const struct cfg *cfg)
{
	const char *root = tracefs_root(cfg->tracefs);
	if (!root)
		return 0;
	char dir[512];
	snprintf(dir, sizeof dir, "%s/instances/%s", root, cfg->instance);
	if (rmdir(dir) && errno != ENOENT) {
		logmsg("rmdir %s: %s", dir, strerror(errno));
		return 1;
	}
	return 0;
}

// run the rhizo-delayd main loop
static int run_daemon(const struct cfg *cfg)
{
	const char *root = tracefs_root(cfg->tracefs);
	if (!root) {
		logmsg("no writable tracefs instances directory");
		return 1;
	}
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);
	struct inst in;
	if (inst_setup(&in, root, cfg->instance, cfg->buffer_kb))
		return 1;
	struct engine e;
	eng_init(&e, &REAL_OPS, (int)getpid(), in.ncpu);
	eng_rescan(&e);
	int lfd = listen_socket(cfg->socket_path);
	if (lfd < 0) {
		inst_teardown(&in);
		return 1;
	}

	struct evq *q = xcalloc((size_t)in.ncpu, sizeof *q);
	u8 *page = xcalloc(1, (size_t)in.L.pg.page_size);
	struct decode_stats ds;
	memset(&ds, 0, sizeof ds);
	logmsg("RHIZO_MARKER delayd_ready cpus=%d buffer_kb=%d", in.ncpu, cfg->buffer_kb);
	sd_notify_ready();

	u64 next_tick = boottime_ns(), next_rescan = next_tick + RESCAN_NS, last_rescan = next_tick;
	u64 next_stats = next_tick + STATS_NS, next_status = next_tick;
	int nconn = 0;
	while (!g_stop) {
		u64 now = boottime_ns();
		int to = now < next_tick ? (int)((next_tick - now) / 1000000) + 1 : 0;
		struct pollfd pf = { lfd, POLLIN, 0 };
		if (poll(&pf, 1, to) > 0 && (pf.revents & POLLIN))
			accept_new(&e, lfd);
		now = boottime_ns();
		if (now < next_tick)
			continue;
		next_tick = now + TICK_NS;
		if (now >= next_rescan || (e.rescan_wanted && now >= last_rescan + RESCAN_MIN_NS)) {
			eng_rescan(&e);
			last_rescan = now;
			next_rescan = now + RESCAN_NS;
		}
		u64 wm = watermark(now);
		for (int pass = 0; pass < 8; pass++) {
			int capped = 0;
			for (int c = 0; c < in.ncpu; c++)
				capped |= read_cpu(&in, c, &q[c], page, &ds, &e.malformed);
			merge_run(&e, q, in.ncpu, wm);
			if (!capped)
				break;
		}
		if (now >= next_stats) {
			next_stats = now + STATS_NS;
			for (int c = 0; c < in.ncpu; c++) {
				u64 d = inst_drops(&in, c);
				if (d > in.drop_prev[c]) {
					in.drop_prev[c] = d;
					e.lost_drops++;
					struct ev m;
					memset(&m, 0, sizeof m);
					m.kind = K_LOSS;
					m.cpu = (u16)c;
					m.ts = q[c].n ? q[c].v[q[c].head + q[c].n - 1].ts : wm;
					evq_push(&q[c], &m);
				}
			}
		}
		eng_tick(&e, wm);
		nconn = service_conns(&e);
		if (now >= next_status) {
			next_status = now + STATUS_NS;
			char buf[16384];
			if (status_build(&e, &ds, nconn, buf, sizeof buf) > 0 && write_status_atomic(cfg->status_path, buf))
				logmsg("status %s: %s", cfg->status_path, strerror(errno));
		}
	}
	close(lfd);
	unlink(cfg->socket_path);
	inst_teardown(&in);
	logmsg("stopped");
	return 0;
}

struct dline {
	u64 ts, seq;
	char text[480];
};

struct dumpctx {
	const struct layout *L;
	struct dline *v;
	size_t n, cap;
	u64 seq;
};

// format a task state mask as letters
static void fmt_state(char *out, size_t n, u64 st, const struct layout *L)
{
	static const struct { u64 bit; char ch; } T[] = {
		{ 1, 'S' }, { 2, 'D' }, { 4, 'T' }, { 8, 't' }, { 0x10, 'X' }, { 0x20, 'Z' }, { 0x40, 'P' }, { 0x80, 'I' },
	};
	u64 m = st & L->run_mask & ~L->preempt_flag;
	size_t o = 0;
	if (!m)
		o += (size_t)snprintf(out + o, n - o, "R");
	for (size_t i = 0; i < sizeof T / sizeof T[0] && m; i++)
		if (m & T[i].bit) {
			o += (size_t)snprintf(out + o, n - o, "%s%c", o ? "|" : "", T[i].ch);
			m &= ~T[i].bit;
		}
	if (st & L->preempt_flag)
		snprintf(out + o, n - o, "+");
}

// decode a raw event and add its text line to the dump
static void dump_cb(void *ctx, const struct rawev *r)
{
	struct dumpctx *d = ctx;
	const struct layout *L = d->L;
	if (d->n == d->cap) {
		d->cap = d->cap ? d->cap * 2 : 4096;
		d->v = xrealloc(d->v, d->cap * sizeof *d->v);
	}
	struct dline *dl = &d->v[d->n++];
	dl->ts = r->ts;
	dl->seq = d->seq++;
	size_t o = (size_t)snprintf(dl->text, sizeof dl->text, "[%03d] %5llu.%06llu: ", r->cpu,
				    (unsigned long long)(r->ts / 1000000000ULL),
				    (unsigned long long)(r->ts % 1000000000ULL / 1000));
	if (r->id == -1) {
		snprintf(dl->text + o, sizeof dl->text - o, "[LOST EVENTS]");
		return;
	}
	int k;
	for (k = 0; k < N_EV; k++)
		if (L->id[k] == r->id)
			break;
	if (k == N_EV) {
		snprintf(dl->text + o, sizeof dl->text - o, "event_%d", r->id);
		return;
	}
	const struct evfmt *f = &L->evfmt[k];
	o += (size_t)snprintf(dl->text + o, sizeof dl->text - o, "%s:", f->name);
	for (int i = 0; i < f->nf && o < sizeof dl->text - 80; i++) {
		const struct field *fl = &f->f[i];
		if (!strncmp(fl->name, "common_", 7))
			continue;
		const char *nm = fl->name;
		if (k == K_FORK && !strcmp(nm, "parent_comm"))
			nm = "comm";
		else if (k == K_FORK && !strcmp(nm, "parent_pid"))
			nm = "pid";
		if (k == K_SWITCH && !strcmp(nm, "next_comm"))
			o += (size_t)snprintf(dl->text + o, sizeof dl->text - o, " ==>");
		if (fl->off + fl->size > (int)r->len) {
			o += (size_t)snprintf(dl->text + o, sizeof dl->text - o, " %s=?", nm);
			continue;
		}
		if (fl->loc && fl->size == 4) {
			u32 dv;
			memcpy(&dv, r->rec + fl->off, 4);
			unsigned so = (dv & 0xffff) + (fl->loc == 2 ? (unsigned)(fl->off + 4) : 0), sl = dv >> 16;
			if (so > r->len)
				so = r->len;
			if (sl > r->len - so)
				sl = r->len - so;
			o += (size_t)snprintf(dl->text + o, sizeof dl->text - o, " %s=%.*s", nm,
					      (int)strnlen((const char *)r->rec + so, sl), (const char *)r->rec + so);
			continue;
		}
		if (strstr(fl->name, "comm")) {
			o += (size_t)snprintf(dl->text + o, sizeof dl->text - o, " %s=%.*s", nm, fl->size,
					      (const char *)r->rec + fl->off);
			continue;
		}
		struct fref fr = { fl->off, fl->size, fl->sgn };
		s64 v = 0;
		fval(r->rec, r->len, &fr, &v);
		if (k == K_SWITCH && !strcmp(nm, "prev_state")) {
			char s[32];
			fmt_state(s, sizeof s, (u64)v, L);
			o += (size_t)snprintf(dl->text + o, sizeof dl->text - o, " prev_state=%s", s);
		} else if (!strcmp(nm, "target_cpu")) {
			o += (size_t)snprintf(dl->text + o, sizeof dl->text - o, " %s=%03lld", nm, (long long)v);
		} else {
			o += (size_t)snprintf(dl->text + o, sizeof dl->text - o, " %s=%lld", nm, (long long)v);
		}
	}
}

// compare two dump lines by time
static int dline_cmp(const void *a, const void *b)
{
	const struct dline *x = a, *y = b;
	if (x->ts != y->ts)
		return x->ts < y->ts ? -1 : 1;
	return x->seq < y->seq ? -1 : x->seq > y->seq;
}

// print the decoded trace events
static int run_dump(const struct cfg *cfg)
{
	const char *root = tracefs_root(cfg->tracefs);
	if (!root) {
		logmsg("no writable tracefs instances directory");
		return 1;
	}
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	struct inst in;
	if (inst_setup(&in, root, cfg->instance, cfg->buffer_kb))
		return 1;
	struct dumpctx d = { &in.L, NULL, 0, 0, 0 };
	u8 *page = xcalloc(1, (size_t)in.L.pg.page_size);
	struct decode_stats ds;
	memset(&ds, 0, sizeof ds);
	u64 end = boottime_ns() + (u64)cfg->dump_secs * 1000000000ULL;
	for (int last = 0; !last && !g_stop;) {
		usleep(20000);
		u64 now = boottime_ns();
		last = now >= end;
		for (int c = 0; c < in.ncpu; c++) {
			if (in.fd[c] < 0)
				continue;
			for (;;) {
				ssize_t n = read(in.fd[c], page, (size_t)in.L.pg.page_size);
				if (n < 0 && errno == EINTR)
					continue;
				if (n <= 0)
					break;
				decode_page(&in.L.pg, c, page, (size_t)n, dump_cb, &d, &ds);
			}
		}
		u64 wm = last ? ~0ULL : watermark(now);
		qsort(d.v, d.n, sizeof *d.v, dline_cmp);
		size_t k = 0;
		while (k < d.n && d.v[k].ts <= wm)
			puts(d.v[k++].text);
		if (k) {
			memmove(d.v, d.v + k, (d.n - k) * sizeof *d.v);
			d.n -= k;
		}
	}
	fflush(stdout);
	logmsg("dumped %llu events, %llu malformed", (unsigned long long)ds.events, (unsigned long long)ds.malformed);
	free(d.v);
	free(page);
	inst_teardown(&in);
	return 0;
}

static int T_pass, T_fail;
static const char *T_case = "";

#define CHECK(cond, ...) \
	do { \
		if (cond) { \
			T_pass++; \
		} else { \
			T_fail++; \
			fprintf(stderr, "FAIL [%s] line %d: ", T_case, __LINE__); \
			fprintf(stderr, __VA_ARGS__); \
			fputc('\n', stderr); \
		} \
	} while (0)

#define MS 1000000ULL
#define US 1000ULL

struct tfield {
	const char *decl, *name;
	int off, size, sgn;
};
struct tev {
	const char *name;
	int id, reclen;
	struct tfield f[10];
	const char *print;
};
struct tfix {
	const char *hp;
	int data_off, data_size, commit_size;
	struct tev ev[N_EV];
};

#define MASK_A "((((0x00000000 | 0x00000001 | 0x00000002 | 0x00000004 | 0x00000008 | 0x00000010 | 0x00000020 | 0x00000040) + 1) << 1) - 1)"
#define FLAG_A "(((0x00000000 | 0x00000001 | 0x00000002 | 0x00000004 | 0x00000008 | 0x00000010 | 0x00000020 | 0x00000040) + 1) << 1)"
#define PRINT_SWITCH_A \
	"\"prev_comm=%s prev_pid=%d prev_prio=%d prev_state=%s%s ==> next_comm=%s next_pid=%d next_prio=%d\", " \
	"REC->prev_comm, REC->prev_pid, REC->prev_prio, (REC->prev_state & " MASK_A ") ? " \
	"__print_flags(REC->prev_state & " MASK_A ", \"|\", { 0x0001, \"S\" }, { 0x0002, \"D\" }, { 0x0004, \"T\" }, " \
	"{ 0x0008, \"t\" }, { 0x0010, \"X\" }, { 0x0020, \"Z\" }, { 0x0040, \"P\" }, { 0x0080, \"I\" }) : \"R\", " \
	"REC->prev_state & " FLAG_A " ? \"+\" : \"\", REC->next_comm, REC->next_pid, REC->next_prio"
#define MASK_B "((((0x0 | 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x80) + 1) << 1) - 1)"
#define FLAG_B "(((0x0 | 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x80) + 1) << 1)"
#define PRINT_SWITCH_B \
	"\"prev_comm=%s prev_state=%s%s\", REC->prev_comm, (REC->prev_state & " MASK_B ") ? \"S\" : \"R\", " \
	"REC->prev_state & " FLAG_B " ? \"+\" : \"\""
#define PRINT_WAKE "\"comm=%s pid=%d prio=%d target_cpu=%03d\", REC->comm, REC->pid, REC->prio, REC->target_cpu"

static const struct tfix FIX_A = {
	"\tfield: u64 timestamp;\toffset:0;\tsize:8;\tsigned:0;\n"
	"\tfield: local_t commit;\toffset:8;\tsize:8;\tsigned:1;\n"
	"\tfield: int overwrite;\toffset:8;\tsize:1;\tsigned:1;\n"
	"\tfield: char data;\toffset:16;\tsize:4080;\tsigned:1;\n",
	16, 4080, 8,
	{
		{ "sched_switch", 316, 64, {
			{ "char prev_comm[16]", "prev_comm", 8, 16, 0 }, { "pid_t prev_pid", "prev_pid", 24, 4, 1 },
			{ "int prev_prio", "prev_prio", 28, 4, 1 }, { "long prev_state", "prev_state", 32, 8, 1 },
			{ "char next_comm[16]", "next_comm", 40, 16, 0 }, { "pid_t next_pid", "next_pid", 56, 4, 1 },
			{ "int next_prio", "next_prio", 60, 4, 1 } }, PRINT_SWITCH_A },
		{ "sched_waking", 317, 36, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "pid_t pid", "pid", 24, 4, 1 },
			{ "int prio", "prio", 28, 4, 1 }, { "int target_cpu", "target_cpu", 32, 4, 1 } }, PRINT_WAKE },
		{ "sched_wakeup", 318, 36, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "pid_t pid", "pid", 24, 4, 1 },
			{ "int prio", "prio", 28, 4, 1 }, { "int target_cpu", "target_cpu", 32, 4, 1 } }, PRINT_WAKE },
		{ "sched_wakeup_new", 319, 36, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "pid_t pid", "pid", 24, 4, 1 },
			{ "int prio", "prio", 28, 4, 1 }, { "int target_cpu", "target_cpu", 32, 4, 1 } }, PRINT_WAKE },
		{ "sched_migrate_task", 320, 40, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "pid_t pid", "pid", 24, 4, 1 },
			{ "int prio", "prio", 28, 4, 1 }, { "int orig_cpu", "orig_cpu", 32, 4, 1 },
			{ "int dest_cpu", "dest_cpu", 36, 4, 1 } }, "\"comm=%s\", REC->comm" },
		{ "sched_process_fork", 321, 48, {
			{ "char parent_comm[16]", "parent_comm", 8, 16, 0 }, { "pid_t parent_pid", "parent_pid", 24, 4, 1 },
			{ "char child_comm[16]", "child_comm", 28, 16, 0 }, { "pid_t child_pid", "child_pid", 44, 4, 1 } },
		  "\"comm=%s\", REC->parent_comm" },
		{ "sched_process_exit", 322, 32, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "pid_t pid", "pid", 24, 4, 1 },
			{ "int prio", "prio", 28, 4, 1 } }, "\"comm=%s\", REC->comm" },
	},
};

static const struct tfix FIX_B = {
	"\tfield: u64 timestamp;\toffset:0;\tsize:8;\tsigned:0;\n"
	"\tfield: local_t commit;\toffset:8;\tsize:4;\tsigned:1;\n"
	"\tfield: char data;\toffset:12;\tsize:4084;\tsigned:1;\n",
	12, 4084, 4,
	{
		{ "sched_switch", 11, 60, {
			{ "char prev_comm[16]", "prev_comm", 8, 16, 0 }, { "pid_t prev_pid", "prev_pid", 24, 4, 1 },
			{ "int prev_prio", "prev_prio", 28, 4, 1 }, { "unsigned int prev_state", "prev_state", 32, 4, 0 },
			{ "char next_comm[16]", "next_comm", 36, 16, 0 }, { "pid_t next_pid", "next_pid", 52, 4, 1 },
			{ "int next_prio", "next_prio", 56, 4, 1 } }, PRINT_SWITCH_B },
		{ "sched_waking", 12, 36, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "int target_cpu", "target_cpu", 24, 4, 1 },
			{ "pid_t pid", "pid", 28, 4, 1 }, { "int prio", "prio", 32, 4, 1 } }, PRINT_WAKE },
		{ "sched_wakeup", 13, 36, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "int target_cpu", "target_cpu", 24, 4, 1 },
			{ "pid_t pid", "pid", 28, 4, 1 }, { "int prio", "prio", 32, 4, 1 } }, PRINT_WAKE },
		{ "sched_wakeup_new", 14, 36, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "int target_cpu", "target_cpu", 24, 4, 1 },
			{ "pid_t pid", "pid", 28, 4, 1 }, { "int prio", "prio", 32, 4, 1 } }, PRINT_WAKE },
		{ "sched_migrate_task", 15, 40, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "pid_t pid", "pid", 24, 4, 1 },
			{ "int prio", "prio", 28, 4, 1 }, { "int dest_cpu", "dest_cpu", 32, 4, 1 },
			{ "int orig_cpu", "orig_cpu", 36, 4, 1 } }, "\"comm=%s\", REC->comm" },
		{ "sched_process_fork", 16, 48, {
			{ "char parent_comm[16]", "parent_comm", 8, 16, 0 }, { "pid_t parent_pid", "parent_pid", 24, 4, 1 },
			{ "char child_comm[16]", "child_comm", 28, 16, 0 }, { "pid_t child_pid", "child_pid", 44, 4, 1 } },
		  "\"comm=%s\", REC->parent_comm" },
		{ "sched_process_exit", 17, 32, {
			{ "char comm[16]", "comm", 8, 16, 0 }, { "pid_t pid", "pid", 24, 4, 1 },
			{ "int prio", "prio", 28, 4, 1 } }, "\"comm=%s\", REC->comm" },
	},
};

static const char HEADER_EVENT[] =
	"# compressed entry header\n\ttype_len    :    5 bits\n\ttime_delta  :   27 bits\n\tarray       :   32 bits\n\n"
	"\tpadding     : type == 29\n\ttime_extend : type == 30\n\ttime_stamp  : type == 31\n\tdata max type_len  == 28\n";

static char FMT_TEXT[N_EV][8192];

// generate the format text of a test event
static void gen_format(char *out, size_t cap, const struct tev *e)
{
	size_t o = (size_t)snprintf(out, cap, "name: %s\nID: %d\nformat:\n"
		"\tfield:unsigned short common_type;\toffset:0;\tsize:2;\tsigned:0;\n"
		"\tfield:unsigned char common_flags;\toffset:2;\tsize:1;\tsigned:0;\n"
		"\tfield:unsigned char common_preempt_count;\toffset:3;\tsize:1;\tsigned:0;\n"
		"\tfield:int common_pid;\toffset:4;\tsize:4;\tsigned:1;\n\n", e->name, e->id);
	for (int i = 0; i < 10 && e->f[i].decl; i++)
		o += (size_t)snprintf(out + o, cap - o, "\tfield:%s;\toffset:%d;\tsize:%d;\tsigned:%d;\n", e->f[i].decl,
				      e->f[i].off, e->f[i].size, e->f[i].sgn);
	snprintf(out + o, cap - o, "\nprint fmt: %s\n", e->print);
}

// build a layout from the test fixture
static int fixture_layout(struct layout *L, const struct tfix *F)
{
	const char *fp[N_EV];
	for (int i = 0; i < N_EV; i++) {
		gen_format(FMT_TEXT[i], sizeof FMT_TEXT[i], &F->ev[i]);
		fp[i] = FMT_TEXT[i];
	}
	return layout_build(L, F->hp, HEADER_EVENT, fp);
}

// zero a record and set its event id
static void rec_init(u8 *rec, const struct tev *e)
{
	memset(rec, 0, 128);
	u16 id = (u16)e->id;
	memcpy(rec, &id, 2);
}

// set a numeric field of a test record
static void rec_set(u8 *rec, const struct tev *e, const char *name, s64 v)
{
	for (int i = 0; i < 10 && e->f[i].decl; i++)
		if (!strcmp(e->f[i].name, name)) {
			if (e->f[i].size == 4) { int32_t x = (int32_t)v; memcpy(rec + e->f[i].off, &x, 4); }
			else if (e->f[i].size == 8) { memcpy(rec + e->f[i].off, &v, 8); }
			return;
		}
	abort();
}

// set a string field of a test record
static void rec_str(u8 *rec, const struct tev *e, const char *name, const char *s)
{
	for (int i = 0; i < 10 && e->f[i].decl; i++)
		if (!strcmp(e->f[i].name, name)) {
			snprintf((char *)rec + e->f[i].off, (size_t)e->f[i].size, "%s", s);
			return;
		}
	abort();
}

// build a sched_switch test record
static unsigned rec_switch(u8 *rec, const struct tfix *F, int prev, int next, s64 state, const char *pc, const char *nc)
{
	const struct tev *e = &F->ev[K_SWITCH];
	rec_init(rec, e);
	rec_str(rec, e, "prev_comm", pc);
	rec_set(rec, e, "prev_pid", prev);
	rec_set(rec, e, "prev_prio", 120);
	rec_set(rec, e, "prev_state", state);
	rec_str(rec, e, "next_comm", nc);
	rec_set(rec, e, "next_pid", next);
	rec_set(rec, e, "next_prio", 120);
	return (unsigned)e->reclen;
}

// build a wake test record
static unsigned rec_wake(u8 *rec, const struct tfix *F, int kind, int pid, int cpu, const char *comm)
{
	const struct tev *e = &F->ev[kind];
	rec_init(rec, e);
	rec_str(rec, e, "comm", comm);
	rec_set(rec, e, "pid", pid);
	rec_set(rec, e, "prio", 120);
	rec_set(rec, e, "target_cpu", cpu);
	return (unsigned)e->reclen;
}

// build a migrate test record
static unsigned rec_migrate(u8 *rec, const struct tfix *F, int pid, int orig, int dest)
{
	const struct tev *e = &F->ev[K_MIGRATE];
	rec_init(rec, e);
	rec_str(rec, e, "comm", "mig");
	rec_set(rec, e, "pid", pid);
	rec_set(rec, e, "orig_cpu", orig);
	rec_set(rec, e, "dest_cpu", dest);
	return (unsigned)e->reclen;
}

// build a fork test record
static unsigned rec_fork(u8 *rec, const struct tfix *F, int parent, int child)
{
	const struct tev *e = &F->ev[K_FORK];
	rec_init(rec, e);
	rec_str(rec, e, "parent_comm", "par");
	rec_set(rec, e, "parent_pid", parent);
	rec_str(rec, e, "child_comm", "chi");
	rec_set(rec, e, "child_pid", child);
	return (unsigned)e->reclen;
}

// build an exit test record
static unsigned rec_exit(u8 *rec, const struct tfix *F, int pid)
{
	const struct tev *e = &F->ev[K_EXIT];
	rec_init(rec, e);
	rec_str(rec, e, "comm", "ex");
	rec_set(rec, e, "pid", pid);
	return (unsigned)e->reclen;
}

struct pb {
	const struct tfix *F;
	u8 page[8192];
	size_t off;
	u64 ts;
};

// start a test page buffer at a base time
static void pb_init(struct pb *p, const struct tfix *F, u64 base)
{
	memset(p, 0, sizeof *p);
	p->F = F;
	p->ts = base;
	memcpy(p->page, &base, 8);
}
// return the write position in the test page
static u8 *pb_at(struct pb *p) { return p->page + p->F->data_off + p->off; }
// append a 32-bit value to the test page
static void pb_put32(struct pb *p, u32 v) { memcpy(pb_at(p), &v, 4); p->off += 4; }
// append an event header to the test page
static void pb_hdr(struct pb *p, int type_len, u64 delta) { pb_put32(p, (u32)((delta << 5) | (u32)type_len)); }

// compute the time delta of an event
static void pb_delta(struct pb *p, u64 ts, u64 *delta)
{
	*delta = ts - p->ts;
	p->ts = ts;
	if (*delta >= (1ULL << 27)) {
		pb_hdr(p, 30, *delta & ((1ULL << 27) - 1));
		pb_put32(p, (u32)(*delta >> 27));
		*delta = 0;
	}
}

// append an event to the test page
static void pb_ev(struct pb *p, u64 ts, const u8 *rec, unsigned reclen)
{
	u64 d;
	pb_delta(p, ts, &d);
	pb_hdr(p, (int)(reclen / 4), d);
	memcpy(pb_at(p), rec, reclen);
	p->off += reclen;
}

// append a large event to the test page
static void pb_big(struct pb *p, u64 ts, const u8 *rec, unsigned reclen)
{
	u64 d;
	pb_delta(p, ts, &d);
	pb_hdr(p, 0, d);
	pb_put32(p, reclen + 4);
	memcpy(pb_at(p), rec, reclen);
	p->off += reclen;
}

// write a padding event of reclen bytes
static void pb_discard(struct pb *p, u64 ts, unsigned reclen)
{
	u64 d;
	pb_delta(p, ts, &d);
	pb_hdr(p, 29, d);
	pb_put32(p, reclen);
	memset(pb_at(p), 0xee, reclen - 4);
	p->off += reclen - 4;
}

// append an absolute time stamp to the test page
static void pb_abs(struct pb *p, u64 ts)
{
	pb_hdr(p, 31, ts & ((1ULL << 27) - 1));
	pb_put32(p, (u32)(ts >> 27));
	p->ts = ts;
}

// pad the rest of the test page
static void pb_tailpad(struct pb *p)
{
	size_t rem = (size_t)p->F->data_size - p->off;
	pb_hdr(p, 29, 1);
	pb_put32(p, (u32)(rem - 4));
	p->off = (size_t)p->F->data_size;
}

// finish the test page and return its commit size
static size_t pb_finish(struct pb *p, u32 flags, u64 missed)
{
	u64 commit = p->off;
	if (flags & RB_MISSED_STORED)
		memcpy(pb_at(p), &missed, 8);
	commit |= flags;
	if (p->F->commit_size == 8)
		memcpy(p->page + 8, &commit, 8);
	else {
		u32 c = (u32)commit;
		memcpy(p->page + 8, &c, 4);
	}
	return (size_t)(p->F->data_off + p->F->data_size);
}

struct rawcap {
	struct {
		u64 ts;
		int cpu, id;
		unsigned len;
		u8 rec[128];
	} e[32];
	int n;
};
// store a raw event in the capture
static void cap_cb(void *ctx, const struct rawev *r)
{
	struct rawcap *c = ctx;
	if (c->n >= 32)
		return;
	c->e[c->n].ts = r->ts;
	c->e[c->n].cpu = r->cpu;
	c->e[c->n].id = r->id;
	c->e[c->n].len = r->len;
	if (r->rec)
		memcpy(c->e[c->n].rec, r->rec, r->len < 128 ? r->len : 128);
	c->n++;
}

// decode a captured raw event
static struct ev cap_ev(const struct layout *L, const struct rawcap *c, int i, int *ok)
{
	struct rawev r = { c->e[i].ts, c->e[i].cpu, c->e[i].id, c->e[i].rec, c->e[i].len };
	struct ev e;
	memset(&e, 0, sizeof e);
	*ok = raw_to_ev(L, &r, &e);
	return e;
}

// test decode_page and raw_to_ev
static void test_decoder(void)
{
	struct layout A, B;
	T_case = "layout A parse";
	CHECK(fixture_layout(&A, &FIX_A) == 0, "layout A did not build");
	CHECK(A.pg.page_size == 4096 && A.pg.data_off == 16 && A.pg.commit_size == 8 && A.pg.ts_off == 0 &&
	      A.pg.commit_off == 8, "page header A %d/%d/%d", A.pg.page_size, A.pg.data_off, A.pg.commit_size);
	CHECK(A.pg.type_padding == 29 && A.pg.type_extend == 30 && A.pg.type_stamp == 31 && A.pg.data_max == 28,
	      "header_event types");
	CHECK(A.sw_prev.off == 24 && A.sw_next.off == 56 && A.sw_state.off == 32 && A.sw_state.size == 8 &&
	      A.sw_state.sgn == 1, "sched_switch offsets %d %d %d", A.sw_prev.off, A.sw_next.off, A.sw_state.off);
	CHECK(A.wk_pid[0].off == 24 && A.wk_cpu[0].off == 32 && A.mg_orig.off == 32 && A.mg_dest.off == 36 &&
	      A.fk_child.off == 44 && A.ex_pid.off == 24, "other offsets");
	CHECK(A.id[K_SWITCH] == 316 && A.id[K_EXIT] == 322, "ids");
	CHECK(A.run_mask == 0xff && A.preempt_flag == 0x100 && !A.fmt_default, "A masks %llx %llx fallback=%d",
	      (unsigned long long)A.run_mask, (unsigned long long)A.preempt_flag, A.fmt_default);

	T_case = "layout B parse (nothing hard-coded)";
	CHECK(fixture_layout(&B, &FIX_B) == 0, "layout B did not build");
	CHECK(B.pg.page_size == 4096 && B.pg.data_off == 12 && B.pg.commit_size == 4, "page header B");
	CHECK(B.sw_state.off == 32 && B.sw_state.size == 4 && B.sw_state.sgn == 0 && B.sw_next.off == 52,
	      "B switch offsets");
	CHECK(B.wk_cpu[0].off == 24 && B.wk_pid[0].off == 28 && B.mg_dest.off == 32 && B.mg_orig.off == 36, "B wake/migrate");
	CHECK(B.run_mask == 0x1ff && B.preempt_flag == 0x200 && !B.fmt_default, "B masks %llx %llx",
	      (unsigned long long)B.run_mask, (unsigned long long)B.preempt_flag);

	T_case = "print fmt default";
	{
		struct tfix bad = FIX_A;
		bad.ev[K_SWITCH].print = "\"prev_state=%d\", REC->prev_state";
		struct layout F;
		CHECK(fixture_layout(&F, &bad) == 0 && F.fmt_default && F.run_mask == 0xff && F.preempt_flag == 0x100,
		      "an unreadable print fmt falls back to 6.8's masks");
		bad.ev[K_SWITCH].print = "\"x\", REC->prev_state & (0x1 << ), REC->prev_state & (0x2 +)";
		CHECK(fixture_layout(&F, &bad) == 0 && F.fmt_default, "a print fmt with broken arithmetic falls back");
	}

	T_case = "malformed formats are refused";
	{
		struct layout F;
		const char *fp[N_EV];
		for (int i = 0; i < N_EV; i++)
			fp[i] = FMT_TEXT[i];
		fixture_layout(&F, &FIX_A);
		CHECK(layout_build(&F, "garbage", HEADER_EVENT, fp) != 0, "header_page garbage accepted");
		CHECK(layout_build(&F, FIX_A.hp, "type_len : 6 bits\ntime_delta : 26 bits\n", fp) != 0,
		      "a header that is not the 5/27 compressed one accepted");
		fp[K_FORK] = "name: sched_process_fork\nID: 5\nformat:\n\tfield:int common_pid;\toffset:4;\tsize:4;\tsigned:1;\n";
		CHECK(layout_build(&F, FIX_A.hp, HEADER_EVENT, fp) != 0, "an event missing its fields accepted");
	}

	T_case = "decode: delta, discard, big, extend, absolute, tail padding";
	{
		struct pb p;
		u8 rec[128];
		struct decode_stats st;
		struct rawcap cap;
		memset(&st, 0, sizeof st);
		memset(&cap, 0, sizeof cap);
		u64 base = 1000000;
		pb_init(&p, &FIX_A, base);
		unsigned n = rec_switch(rec, &FIX_A, 100, 200, 1, "swapper/3", "HOSTSECRET");
		pb_ev(&p, base + 1000, rec, n);
		n = rec_wake(rec, &FIX_A, K_WAKING, 300, 2, "wk");
		pb_ev(&p, base + 1500, rec, n);
		pb_discard(&p, base + 2200, 36);
		n = rec_wake(rec, &FIX_A, K_WAKEUP, 300, 4, "wk");
		pb_ev(&p, base + 3000, rec, n);
		n = rec_migrate(rec, &FIX_A, 300, 2, 5);
		pb_big(&p, base + 3100, rec, n);
		n = rec_exit(rec, &FIX_A, 300);
		pb_ev(&p, base + 3100 + 300000000ULL, rec, n);
		pb_abs(&p, 9000000000ULL);
		n = rec_fork(rec, &FIX_A, 1, 2);
		pb_ev(&p, 9000000100ULL, rec, n);
		pb_tailpad(&p);
		size_t sz = pb_finish(&p, 0, 0);
		decode_page(&A.pg, 3, p.page, sz, cap_cb, &cap, &st);
		CHECK(cap.n == 6, "decoded %d events, want 6", cap.n);
		CHECK(st.events == 6 && st.padding == 2 && st.malformed == 0 && st.pages == 1, "stats ev=%llu pad=%llu bad=%llu",
		      (unsigned long long)st.events, (unsigned long long)st.padding, (unsigned long long)st.malformed);
		static const u64 want_ts[6] = { 1001000, 1001500 + 0, 1003000, 1003100, 1003100 + 300000000ULL, 9000000100ULL };
		for (int i = 0; i < cap.n && i < 6; i++)
			CHECK(cap.e[i].ts == (i == 1 ? 1001500 : want_ts[i]) && cap.e[i].cpu == 3, "event %d ts=%llu cpu=%d", i,
			      (unsigned long long)cap.e[i].ts, cap.e[i].cpu);
		int ok;
		struct ev e = cap_ev(&A, &cap, 0, &ok);
		CHECK(ok == 1 && e.kind == K_SWITCH && e.a == 100 && e.b == 200 && e.c == 0, "switch: a=%d b=%d c=%d", e.a, e.b, e.c);
		e = cap_ev(&A, &cap, 1, &ok);
		CHECK(ok == 1 && e.kind == K_WAKING && e.a == 300 && e.b == 2, "waking");
		e = cap_ev(&A, &cap, 2, &ok);
		CHECK(ok == 1 && e.kind == K_WAKEUP && e.a == 300 && e.b == 4, "wakeup after the discarded event");
		e = cap_ev(&A, &cap, 3, &ok);
		CHECK(ok == 1 && e.kind == K_MIGRATE && e.a == 300 && e.b == 2 && e.c == 5, "migrate from a type_len 0 event: a=%d b=%d c=%d", e.a, e.b, e.c);
		e = cap_ev(&A, &cap, 4, &ok);
		CHECK(ok == 1 && e.kind == K_EXIT && e.a == 300, "exit across a time extend");
		e = cap_ev(&A, &cap, 5, &ok);
		CHECK(ok == 1 && e.kind == K_FORK && e.a == 1 && e.b == 2, "fork after an absolute time stamp");
	}

	T_case = "decode: missed-events flag";
	{
		struct pb p;
		u8 rec[128];
		struct decode_stats st;
		struct rawcap cap;
		memset(&st, 0, sizeof st);
		memset(&cap, 0, sizeof cap);
		pb_init(&p, &FIX_A, 5000);
		unsigned n = rec_switch(rec, &FIX_A, 1, 2, 0, "a", "b");
		pb_ev(&p, 5100, rec, n);
		size_t sz = pb_finish(&p, RB_MISSED_EVENTS | RB_MISSED_STORED, 7);
		decode_page(&A.pg, 1, p.page, sz, cap_cb, &cap, &st);
		CHECK(cap.n == 2 && cap.e[0].id == -1 && cap.e[0].ts == 5000, "the marker comes first, at the page time");
		CHECK(cap.n == 2 && cap.e[1].ts == 5100, "the page's own events still decode");
		CHECK(st.missed_pages == 1 && st.missed_events == 7, "missed pages=%llu events=%llu",
		      (unsigned long long)st.missed_pages, (unsigned long long)st.missed_events);
		CHECK(st.events == 1 && st.malformed == 0, "length with flags: ev=%llu bad=%llu",
		      (unsigned long long)st.events, (unsigned long long)st.malformed);
	}

	T_case = "decode: end of data, short commit, truncation";
	{
		struct pb p;
		u8 rec[128];
		struct decode_stats st;
		struct rawcap cap;
		unsigned n = rec_switch(rec, &FIX_A, 1, 2, 0, "a", "b");
		memset(&st, 0, sizeof st);
		memset(&cap, 0, sizeof cap);
		pb_init(&p, &FIX_A, 100);
		pb_ev(&p, 110, rec, n);
		pb_hdr(&p, 29, 0);
		pb_put32(&p, 60);
		pb_ev(&p, 120, rec, n);
		size_t sz = pb_finish(&p, 0, 0);
		decode_page(&A.pg, 0, p.page, sz, cap_cb, &cap, &st);
		CHECK(cap.n == 1, "decoded %d events past a null padding event, want 1", cap.n);
		memset(&st, 0, sizeof st);
		memset(&cap, 0, sizeof cap);
		pb_init(&p, &FIX_A, 100);
		pb_ev(&p, 110, rec, n);
		size_t committed = p.off;
		pb_ev(&p, 120, rec, n);
		sz = pb_finish(&p, 0, 0);
		u64 c = committed;
		memcpy(p.page + 8, &c, 8);
		decode_page(&A.pg, 0, p.page, sz, cap_cb, &cap, &st);
		CHECK(cap.n == 1, "decoded %d events, the commit allows 1", cap.n);
		memset(&st, 0, sizeof st);
		memset(&cap, 0, sizeof cap);
		c = 40;
		memcpy(p.page + 8, &c, 8);
		decode_page(&A.pg, 0, p.page, sz, cap_cb, &cap, &st);
		CHECK(cap.n == 0 && st.malformed == 1, "truncated event: n=%d bad=%llu", cap.n, (unsigned long long)st.malformed);
		memset(&st, 0, sizeof st);
		struct rawev r = { 1, 0, 316, rec, 20 };
		struct ev e;
		CHECK(raw_to_ev(&A, &r, &e) == -1, "a 20-byte sched_switch accepted");
		r.id = 9999;
		CHECK(raw_to_ev(&A, &r, &e) == 0, "a foreign event id taken");
	}

	T_case = "decode: layout B (32-bit commit, moved fields)";
	{
		struct pb p;
		u8 rec[128];
		struct decode_stats st;
		struct rawcap cap;
		memset(&st, 0, sizeof st);
		memset(&cap, 0, sizeof cap);
		pb_init(&p, &FIX_B, 777);
		unsigned n = rec_switch(rec, &FIX_B, 11, 22, 0x200, "p", "n");
		pb_ev(&p, 800, rec, n);
		n = rec_switch(rec, &FIX_B, 11, 22, 0x100, "p", "n");
		pb_ev(&p, 810, rec, n);
		n = rec_switch(rec, &FIX_B, 11, 22, 0, "p", "n");
		pb_ev(&p, 820, rec, n);
		n = rec_wake(rec, &FIX_B, K_WAKEUP_NEW, 42, 6, "w");
		pb_ev(&p, 830, rec, n);
		n = rec_migrate(rec, &FIX_B, 42, 3, 6);
		pb_ev(&p, 840, rec, n);
		size_t sz = pb_finish(&p, 0, 0);
		decode_page(&B.pg, 2, p.page, sz, cap_cb, &cap, &st);
		CHECK(cap.n == 5 && st.malformed == 0, "decoded %d", cap.n);
		int ok;
		struct ev e = cap_ev(&B, &cap, 0, &ok);
		CHECK(ok == 1 && e.kind == K_SWITCH && e.a == 11 && e.b == 22 && e.c == 1, "B: 0x200 is the preempt flag, runnable (c=%d)", e.c);
		e = cap_ev(&B, &cap, 1, &ok);
		CHECK(ok == 1 && e.c == 0, "B: 0x100 is a sleeping state here, not runnable (c=%d)", e.c);
		e = cap_ev(&B, &cap, 2, &ok);
		CHECK(ok == 1 && e.c == 1, "B: state 0 runnable");
		e = cap_ev(&B, &cap, 3, &ok);
		CHECK(ok == 1 && e.kind == K_WAKEUP_NEW && e.a == 42 && e.b == 6, "B wakeup_new pid/cpu moved fields: a=%d b=%d", e.a, e.b);
		e = cap_ev(&B, &cap, 4, &ok);
		CHECK(ok == 1 && e.kind == K_MIGRATE && e.a == 42 && e.b == 3 && e.c == 6, "B migrate swapped fields: b=%d c=%d", e.b, e.c);
	}

	T_case = "prev_state runnable decisions (layout A)";
	{
		static const struct { s64 st; int runnable; } cases[] = {
			{ 0, 1 }, { 0x100, 1 }, { 0x1, 0 }, { 0x2, 0 }, { 0x4, 0 }, { 0x40, 0 }, { 0x80, 0 }, { 0x101, 0 }, { 0x102, 0 },
		};
		u8 rec[128];
		for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
			unsigned n = rec_switch(rec, &FIX_A, 1, 2, cases[i].st, "a", "b");
			struct rawev r = { 1, 0, 316, rec, n };
			struct ev e;
			CHECK(raw_to_ev(&A, &r, &e) == 1 && e.c == cases[i].runnable, "prev_state 0x%llx -> runnable=%d, want %d",
			      (unsigned long long)cases[i].st, e.c, cases[i].runnable);
		}
	}

	T_case = "decoder survives garbage pages";
	{
		u8 page[4096];
		u64 x = 88172645463325252ULL;
		struct decode_stats st;
		struct rawcap cap;
		memset(&st, 0, sizeof st);
		for (int i = 0; i < 4000; i++) {
			for (size_t j = 0; j < sizeof page; j++) {
				x ^= x << 13; x ^= x >> 7; x ^= x << 17;
				page[j] = (u8)x;
			}
			if (i & 1) {
				u64 c = (x >> 8) % 4081;
				memcpy(page + 8, &c, 8);
			}
			memset(&cap, 0, sizeof cap);
			decode_page(&A.pg, i & 7, page, sizeof page, cap_cb, &cap, &st);
			for (int k = 0; k < cap.n; k++) {
				int ok;
				cap_ev(&A, &cap, k, &ok);
			}
		}
		CHECK(st.pages == 4000, "pages decoded: %llu", (unsigned long long)st.pages);
	}

	T_case = "dump text";
	{
		struct pb p;
		u8 rec[128];
		struct decode_stats st;
		memset(&st, 0, sizeof st);
		pb_init(&p, &FIX_A, 1000000);
		unsigned n = rec_switch(rec, &FIX_A, 100, 200, 1, "swapper/3", "worker");
		pb_ev(&p, 1001000, rec, n);
		n = rec_wake(rec, &FIX_A, K_WAKING, 300, 2, "wk");
		pb_ev(&p, 1002000, rec, n);
		size_t sz = pb_finish(&p, 0, 0);
		struct dumpctx d = { &A, NULL, 0, 0, 0 };
		decode_page(&A.pg, 3, p.page, sz, dump_cb, &d, &st);
		CHECK(d.n == 2, "dump lines %zu", d.n);
		if (d.n == 2) {
			CHECK(!strcmp(d.v[0].text, "[003]     0.001001: sched_switch: prev_comm=swapper/3 prev_pid=100 prev_prio=120 "
					  "prev_state=S ==> next_comm=worker next_pid=200 next_prio=120"), "dump switch: %s", d.v[0].text);
			CHECK(!strcmp(d.v[1].text, "[003]     0.001002: sched_waking: comm=wk pid=300 prio=120 target_cpu=002"),
			      "dump waking: %s", d.v[1].text);
		}
		free(d.v);
		char s[32];
		fmt_state(s, sizeof s, 0, &A);
		CHECK(!strcmp(s, "R"), "state 0 -> %s", s);
		fmt_state(s, sizeof s, 0x100, &A);
		CHECK(!strcmp(s, "R+"), "state 0x100 -> %s", s);
		fmt_state(s, sizeof s, 3, &A);
		CHECK(!strcmp(s, "S|D"), "state 3 -> %s", s);
	}
}

#define HOSTNS 4026531836ULL
#define NS_A 4026532001ULL
#define NS_B 4026532002ULL
#define NS_C 4026532003ULL
#define NS_D 4026532004ULL

struct fp {
	int tid, tgid, nspid, nstgid, alive, ns_fail;
	u64 ino, ino_children;
	char comm[40], pname[48], attr[48];
};
static struct fp FP[96];
static int NFP;

// find a live fake process by thread id
static struct fp *fp_find(int tid)
{
	for (int i = 0; i < NFP; i++)
		if (FP[i].tid == tid && FP[i].alive)
			return &FP[i];
	return NULL;
}

// add a fake process
static struct fp *fp_add(int tid, int tgid, u64 ino, int nstgid, int nspid, const char *comm, const char *pname,
			 const char *attr, int alive)
{
	struct fp *p = &FP[NFP++];
	memset(p, 0, sizeof *p);
	p->tid = tid;
	p->tgid = tgid;
	p->ino = ino;
	p->ino_children = ino;
	p->nstgid = nstgid;
	p->nspid = nspid;
	p->alive = alive;
	snprintf(p->comm, sizeof p->comm, "%s", comm);
	snprintf(p->pname, sizeof p->pname, "%s", pname);
	snprintf(p->attr, sizeof p->attr, "%s", attr);
	return p;
}

// list the fake process ids
static int fake_list_pids(void *c, int **out)
{
	(void)c;
	int *v = xcalloc((size_t)NFP + 1, sizeof *v), n = 0;
	for (int i = 0; i < NFP; i++)
		if (FP[i].alive && FP[i].tid == FP[i].tgid)
			v[n++] = FP[i].tid;
	*out = v;
	return n;
}
// list the fake thread ids of a process
static int fake_list_tids(void *c, int pid, int **out)
{
	(void)c;
	int *v = xcalloc((size_t)NFP + 1, sizeof *v), n = 0;
	for (int i = 0; i < NFP; i++)
		if (FP[i].alive && FP[i].tgid == pid)
			v[n++] = FP[i].tid;
	*out = v;
	return n;
}
// return the fake pid namespace inode of a thread
static int fake_pid_ns(void *c, int tid, u64 *ino)
{
	(void)c;
	struct fp *p = fp_find(tid);
	if (!p || p->ns_fail)
		return -1;
	*ino = p->ino;
	return 0;
}
// return the fake child pid namespace inode of a thread
static int fake_pid_ns_children(void *c, int tid, u64 *ino)
{
	(void)c;
	struct fp *p = fp_find(tid);
	if (!p)
		return -1;
	*ino = p->ino_children;
	return 0;
}
// return the fake last namespace thread id of a thread
static int fake_nspid_last(void *c, int tid, int *id)
{
	(void)c;
	struct fp *p = fp_find(tid);
	if (!p)
		return -1;
	*id = p->nspid;
	return 0;
}
// return the fake namespace thread group id and thread id
static int fake_ids(void *c, int tid, int *ntgid, int *ntid)
{
	(void)c;
	struct fp *p = fp_find(tid);
	if (!p)
		return -1;
	*ntgid = p->nstgid;
	*ntid = p->nspid;
	return 0;
}
// return the fake security context of a process
static int fake_attr(void *c, int pid, char *buf, size_t n)
{
	(void)c;
	struct fp *p = fp_find(pid);
	if (!p || !p->attr[0])
		return -1;
	snprintf(buf, n, "%s", p->attr);
	return 0;
}
// return the fake command name of a thread
static int fake_comm(void *c, int tid, char *buf, size_t n)
{
	(void)c;
	struct fp *p = fp_find(tid);
	if (!p)
		return -1;
	snprintf(buf, n, "%s", p->comm);
	return 0;
}
// return the fake process name of a thread
static int fake_pname(void *c, int tid, char *buf, size_t n)
{
	(void)c;
	struct fp *p = fp_find(tid);
	if (!p)
		return -1;
	snprintf(buf, n, "%s", p->pname);
	return 0;
}

static const struct procops FAKE_OPS = {
	NULL, fake_list_pids, fake_list_tids, fake_pid_ns, fake_nspid_last, fake_ids, fake_attr, fake_comm, fake_pname,
	fake_pid_ns_children,
};

#define T1 1000
#define T2 1001
#define T3 1002
#define TSF 1100
#define TB 1700
#define HOST1 7001
#define HOST2 7002
#define HOST3 31337

static struct engine E;
static struct sbx *SA, *SB;
static struct conn *CA, *CB;
static char ALLOUT[1 << 20];

// create the fake /proc and the engine
static void world(int connect)
{
	NFP = 0;
	fp_add(9999, 9999, HOSTNS, 9999, 9999, "rhizo-delayd", "rhizo-delayd", "u:r:rhizo_delayd:s0", 1);
	fp_add(500, 500, NS_A, 1, 1, "init", "/system/bin/init", INIT_CTX, 1);
	fp_add(T1, 1000, NS_A, 2000, 2000, "UiThread", "com.test.app", "u:r:untrusted_app:s0", 1);
	fp_add(T2, 1000, NS_A, 2000, 2001, "RenderThread", "com.test.app", "u:r:untrusted_app:s0", 1);
	fp_add(T3, 1000, NS_A, 2000, 2002, "Other", "com.test.app", "u:r:untrusted_app:s0", 1);
	fp_add(TSF, 1100, NS_A, 2100, 2100, "sf", "surfaceflinger", "u:r:surfaceflinger:s0", 1);
	fp_add(600, 600, NS_B, 1, 1, "init", "/system/bin/init", INIT_CTX, 1);
	fp_add(TB, 1700, NS_B, 3000, 3000, "bthread", "other.app", "u:r:untrusted_app:s0", 1);
	fp_add(800, 800, NS_C, 1, 1, "init", "/sbin/init", "u:r:init_t:s0", 1);
	fp_add(801, 801, NS_C, 5, 5, "worker", "worker", "u:r:init:s0", 1);
	fp_add(HOST1, HOST1, HOSTNS, HOST1, HOST1, "HOSTSECRET-rt-load", "HOSTSECRET-rt-load", "u:r:unconfined_t:s0", 1);
	fp_add(HOST2, HOST2, HOSTNS, HOST2, HOST2, "kworker-HOSTSECRET2", "kworker-HOSTSECRET2", "", 1);
	fp_add(HOST3, HOST3, HOSTNS, HOST3, HOST3, "HOSTSECRET3", "HOSTSECRET3", "", 1);
	for (int i = 0; i < NFP; i++)
		if (FP[i].tid == T2 || FP[i].tid == T3)
			FP[i].tgid = 1000;
	eng_init(&E, &FAKE_OPS, 9999, 4);
	eng_rescan(&E);
	SA = sbx_find(&E, NS_A);
	SB = sbx_find(&E, NS_B);
	CA = connect ? conn_new(-1) : NULL;
	CB = NULL;
	if (connect)
		eng_connect(&E, SA, CA);
}

static char OB[1 << 17];
static int OB_PKTS;
// return the text of the packets sent on a connection
static const char *collect(struct conn *c)
{
	size_t o = 0;
	OB_PKTS = 0;
	OB[0] = 0;
	if (!c)
		return OB;
	conn_flushpkt(c);
	while (c->qlen) {
		u16 l;
		memcpy(&l, c->q + c->qhead, 2);
		CHECK(l > 0 && l <= 4096, "packet of %u bytes", l);
		CHECK(c->q[c->qhead + 2 + l - 1] == '\n', "a packet that does not end on a line");
		if (o + l < sizeof OB) {
			memcpy(OB + o, c->q + c->qhead + 2, l);
			o += l;
		}
		OB_PKTS++;
		c->qhead += 2 + (size_t)l;
		c->qlen -= 2 + (size_t)l;
	}
	c->qhead = 0;
	OB[o] = 0;
	if (strlen(ALLOUT) + o < sizeof ALLOUT)
		strcat(ALLOUT, OB);
	return OB;
}

#define EXPECT(conn, want) \
	do { \
		const char *got_ = collect(conn); \
		CHECK(!strcmp(got_, want), "protocol output\n--- got ---\n%s--- want ---\n%s---", got_, want); \
	} while (0)

// feed a sched_switch event to the test engine
static void SW(int cpu, u64 ts, int prev, int next, int runnable)
{
	struct ev v = { ts, prev, next, runnable, 0, K_SWITCH, (u16)cpu };
	eng_event(&E, &v);
}
// feed a wake event to the test engine
static void WK(int kind, u64 ts, int tid, int cpu)
{
	struct ev v = { ts, tid, cpu, 0, 0, (u8)kind, 0 };
	eng_event(&E, &v);
}
// feed a migrate event to the test engine
static void MG(u64 ts, int tid, int from, int to)
{
	struct ev v = { ts, tid, from, to, 0, K_MIGRATE, 0 };
	eng_event(&E, &v);
}
// feed a fork event to the test engine
static void FK(u64 ts, int parent, int child)
{
	struct ev v = { ts, parent, child, 0, 0, K_FORK, 0 };
	eng_event(&E, &v);
}
// feed an exit event to the test engine
static void EX(u64 ts, int tid)
{
	struct ev v = { ts, tid, 0, 0, 0, K_EXIT, 0 };
	eng_event(&E, &v);
}
// feed a lost-events marker to the test engine
static void LOSS(u64 ts, int cpu)
{
	struct ev v = { ts, 0, 0, 0, 0, K_LOSS, (u16)cpu };
	eng_event(&E, &v);
}
// advance the test engine clock
static void TICK(u64 now) { eng_tick(&E, now); }

#define P_APP "p 2000 com.test.app\n"
#define T_UI "t 2000 2000 UiThread\n"

// run the engine scenarios
static void test_scenarios(void)
{
	T_case = "wake onto a host-occupied cpu";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 4 * MS, HOST1, T1, 0);
	SW(0, 5 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 4000000 3000000 1\nc 2000 1 1\n");

	T_case = "preempted by a host task";
	world(1);
	SW(1, 0, 0, T1, 0);
	SW(1, 2 * MS, T1, HOST1, 1);
	SW(1, 5 * MS, HOST1, T1, 0);
	SW(1, 6 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 2000000 5000000 3000000 1\nc 2000 1 1\n");

	T_case = "waiting behind a thread of its own sandbox is not blame";
	world(1);
	SW(0, 0, 0, T2, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 6 * MS, T2, T1, 0);
	SW(0, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP "c 2000 2 0\n");

	T_case = "waiting behind idle is not blame";
	world(1);
	WK(K_WAKING, 1 * MS, T1, 2);
	SW(2, 6 * MS, 0, T1, 0);
	SW(2, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP "c 2000 1 0\n");

	T_case = "adversary: 990 us held, 10 us run, 50 times, one coalesced record";
	world(1);
	SW(0, 0, 0, T1, 0);
	for (u64 i = 0; i < 50; i++) {
		if (i)
			SW(0, i * 1000 * US, HOST1, T1, 0);
		SW(0, i * 1000 * US + 10 * US, T1, HOST1, 1);
	}
	SW(0, 50 * MS, HOST1, T1, 0);
	SW(0, 50 * MS + 10 * US, T1, 0, 0);
	TICK(60 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 10000 50000000 49500000 1\nc 2000 1 1\n");
	{
		double span = 50000000.0 - 10000.0, held = 49500000.0;
		CHECK(held / span > 0.989 && held / span < 0.991, "held is %.3f of the span", held / span);
	}

	T_case = "a gap of exactly 1 ms closes the episode";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 3 * MS, HOST1, T1, 0);
	SW(0, 4 * MS, T1, HOST1, 1);
	SW(0, 6 * MS, HOST1, T1, 0);
	SW(0, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 3000000 2000000 1\nd 2000 2000 4000000 6000000 2000000 1\nc 2000 1 1\n");

	T_case = "a gap of 999 us does not";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 3 * MS, HOST1, T1, 0);
	SW(0, 3 * MS + 999 * US, T1, HOST1, 1);
	SW(0, 6 * MS, HOST1, T1, 0);
	SW(0, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 6000000 4001000 1\nc 2000 1 1\n");

	T_case = "sleep closes an episode that the gap rule would have joined";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 2 * MS, HOST1, T1, 0);
	SW(0, 2200 * US, T1, HOST1, 0);
	WK(K_WAKING, 2300 * US, T1, 0);
	SW(0, 3300 * US, HOST1, T1, 0);
	SW(0, 3400 * US, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 2000000 1000000 1\nd 2000 2000 2300000 3300000 1000000 2\nc 2000 2 0\n");

	T_case = "MAX_SPAN splits a long hold at exact boundaries";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 251 * MS, HOST1, T1, 0);
	SW(0, 252 * MS, T1, 0, 0);
	TICK(300 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 101000000 100000000 1\nd 2000 2000 101000000 201000000 100000000 1\n"
		   "d 2000 2000 201000000 251000000 50000000 1\nc 2000 1 1\n");
	T_case = "MAX_SPAN with other events in between: the span is emitted when time passes, not at the end";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	WK(K_WAKING, 150 * MS, HOST2, 3);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 101000000 100000000 1\n");
	SW(0, 251 * MS, HOST1, T1, 0);
	SW(0, 252 * MS, T1, 0, 0);
	TICK(300 * MS);
	EXPECT(CA, "d 2000 2000 101000000 201000000 100000000 1\nd 2000 2000 201000000 251000000 50000000 1\nc 2000 1 1\n");
	T_case = "MAX_SPAN with only a tick: it emits what has reached the span";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	TICK(150 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 101000000 100000000 1\n");

	T_case = "the gap restarts at every held instant";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 2 * MS, HOST1, T1, 0);
	SW(0, 2600 * US, T1, HOST1, 1);
	SW(0, 2700 * US, HOST1, T1, 0);
	SW(0, 3300 * US, T1, HOST1, 1);
	SW(0, 4300 * US, HOST1, T1, 0);
	SW(0, 4400 * US, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 4300000 2100000 1\nc 2000 1 1\n");

	T_case = "waiting behind idle after a hold closes the episode";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 2 * MS, HOST1, 0, 0);
	SW(0, 3500 * US, 0, T1, 0);
	SW(0, 3600 * US, T1, HOST1, 1);
	SW(0, 4600 * US, HOST1, T1, 0);
	SW(0, 4700 * US, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 2000000 1000000 1\nd 2000 2000 3600000 4600000 1000000 1\nc 2000 1 1\n");

	T_case = "FLOOR drops 0.4 ms, keeps 0.5 ms";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 1400 * US, HOST1, T1, 0);
	SW(0, 1500 * US, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP "c 2000 1 0\n");
	T_case = "FLOOR keeps exactly 0.5 ms";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 1500 * US, HOST1, T1, 0);
	SW(0, 1600 * US, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 1500000 500000 1\nc 2000 1 0\n");
	T_case = "FLOOR drops 499999 ns";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 1 * MS + 499999, HOST1, T1, 0);
	SW(0, 1600 * US, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP "c 2000 1 0\n");

	T_case = "a work period with exactly 2 ms emitted is host-delayed";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 2 * MS, HOST1, T1, 0);
	SW(0, 3 * MS, T1, HOST1, 1);
	SW(0, 4 * MS, HOST1, T1, 0);
	SW(0, 5 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 2000000 1000000 1\nd 2000 2000 3000000 4000000 1000000 1\nc 2000 1 1\n");
	T_case = "a work period with 1999999 ns is not";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 2 * MS, HOST1, T1, 0);
	SW(0, 3 * MS, T1, HOST1, 1);
	SW(0, 3999999, HOST1, T1, 0);
	SW(0, 4999999, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 2000000 1000000 1\nd 2000 2000 3000000 3999999 999999 1\nc 2000 1 0\n");

	T_case = "host_delayed sums whole microseconds, as Android recounts from held_us";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 1 * MS + 666900, HOST1, T1, 0);
	SW(0, 2 * MS + 666900, T1, HOST1, 1);
	SW(0, 2 * MS + 1333800, HOST1, T1, 0);
	SW(0, 3 * MS + 1333800, T1, HOST1, 1);
	SW(0, 3 * MS + 2000700, HOST1, T1, 0);
	SW(0, 3 * MS + 2100700, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 1666900 666900 1\nd 2000 2000 2666900 3333800 666900 1\n"
		   "d 2000 2000 4333800 5000700 666900 1\nc 2000 1 0\n");

	T_case = "sched_migrate_task moves the accounting off the host cpu";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 2 * MS, T1, 0);
	MG(4 * MS, T1, 0, 1);
	SW(1, 6 * MS, 0, T1, 0);
	SW(1, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 2000000 4000000 2000000 1\nc 2000 1 1\n");
	T_case = "sched_migrate_task onto a host cpu starts the hold there";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 2 * MS, T1, 1);
	MG(4 * MS, T1, 1, 0);
	SW(0, 6 * MS, HOST1, T1, 0);
	SW(0, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 4000000 6000000 2000000 1\nc 2000 1 1\n");
	T_case = "sched_wakeup's target cpu replaces sched_waking's";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 2 * MS, T1, 0);
	WK(K_WAKEUP, 2 * MS, T1, 1);
	SW(1, 5 * MS, 0, T1, 0);
	SW(1, 6 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP "c 2000 1 0\n");

	T_case = "fork inherits the namespace, exit drops the entry";
	world(1);
	{
		struct fp *kid = fp_add(1500, 1000, NS_A, 2000, 2500, "forked", "com.test.app", "u:r:untrusted_app:s0", 0);
		kid->ns_fail = 1;
		fp_find(T1)->ino_children = HOSTNS;
		kid->alive = 1;
	}
	FK(0, T1, 1500);
	SW(0, 1 * MS, 0, HOST1, 0);
	WK(K_WAKEUP_NEW, 2 * MS, 1500, 0);
	SW(0, 5 * MS, HOST1, 1500, 0);
	SW(0, 6 * MS, 1500, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP "t 2000 2500 forked\nd 2000 2500 2000000 5000000 3000000 1\nc 2000 1 1\n");
	EX(11 * MS, 1500);
	{
		struct fp *kid = fp_find(1500);
		kid->ns_fail = 0;
		kid->ino = HOSTNS;
		snprintf(kid->attr, sizeof kid->attr, "u:r:unconfined_t:s0");
	}
	SW(1, 18 * MS, 0, 1500, 0);
	WK(K_WAKING, 19 * MS, T2, 1);
	SW(1, 22 * MS, 1500, T2, 0);
	SW(1, 23 * MS, T2, 0, 0);
	TICK(24 * MS);
	EXPECT(CA, "t 2000 2001 RenderThread\nd 2000 2001 19000000 22000000 3000000 1\n");

	T_case = "a thread of another sandbox holds like a host task";
	world(1);
	CB = conn_new(-1);
	eng_connect(&E, SB, CB);
	SW(0, 0, 0, TB, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 4 * MS, TB, T1, 0);
	SW(0, 5 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 4000000 3000000 1\nc 2000 1 1\n");
	EXPECT(CB, "p 3000 other.app\nc 3000 1 0\n");

	T_case = "counts, c throttling, the final c before x";
	world(1);
	WK(K_WAKING, 1 * MS, T1, 2);
	SW(2, 2 * MS, 0, T1, 0);
	SW(2, 3 * MS, T1, 0, 0);
	TICK(20 * MS);
	WK(K_WAKING, 30 * MS, T1, 2);
	SW(2, 31 * MS, 0, T1, 0);
	SW(2, 32 * MS, T1, 0, 0);
	TICK(100 * MS);
	WK(K_WAKING, 110 * MS, T1, 2);
	SW(2, 111 * MS, 0, T1, 0);
	SW(2, 112 * MS, T1, 0, 0);
	TICK(150 * MS);
	TICK(230 * MS);
	EXPECT(CA, P_APP "c 2000 1 0\nc 2000 3 0\n");
	WK(K_WAKING, 300 * MS, TSF, 0);
	SW(0, 301 * MS, 0, TSF, 0);
	SW(0, 302 * MS, TSF, 0, 0);
	TICK(305 * MS);
	WK(K_WAKING, 310 * MS, TSF, 0);
	SW(0, 311 * MS, 0, TSF, 0);
	SW(0, 312 * MS, TSF, 0, 0);
	TICK(315 * MS);
	EX(320 * MS, TSF);
	EXPECT(CA, "p 2100 surfaceflinger\nc 2100 1 0\nc 2100 2 0\nx 2100\n");

	T_case = "a renamed thread and process are announced again, c stays throttled";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 4 * MS, HOST1, T1, 0);
	SW(0, 5 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 4000000 3000000 1\nc 2000 1 1\n");
	snprintf(fp_find(T1)->comm, sizeof fp_find(T1)->comm, "Renamed");
	for (int i = 0; i < NFP; i++)
		if (FP[i].tgid == 1000 && FP[i].nstgid == 2000)
			snprintf(FP[i].pname, sizeof FP[i].pname, "new.name");
	SW(0, 10 * MS, 0, HOST1, 0);
	WK(K_WAKING, 11 * MS, T1, 0);
	SW(0, 14 * MS, HOST1, T1, 0);
	SW(0, 15 * MS, T1, 0, 0);
	TICK(20 * MS);
	EXPECT(CA, "p 2000 new.name\nt 2000 2000 Renamed\nd 2000 2000 11000000 14000000 3000000 2\n");
	TICK(300 * MS);
	EXPECT(CA, "c 2000 2 2\n");

	T_case = "connect sends p + c for processes with counts, replaces the old connection";
	world(0);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 4 * MS, HOST1, T1, 0);
	SW(0, 5 * MS, T1, 0, 0);
	TICK(10 * MS);
	CA = conn_new(-1);
	eng_connect(&E, SA, CA);
	EXPECT(CA, P_APP "c 2000 1 1\n");
	CHECK(SA->conn == CA, "the connection is the newer one");
	struct conn *c2 = conn_new(-1);
	eng_connect(&E, SA, c2);
	EXPECT(c2, P_APP "c 2000 1 1\n");

	T_case = "a lost page: only pre-hole held time is a record";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	TICK(2 * MS);
	LOSS(3 * MS, 0);
	SW(0, 6 * MS, HOST1, T1, 0);
	SW(0, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 2000000 1000000 1\nc 2000 1 0\n");
	CHECK(E.lost_pages == 1, "lost pages counted: %llu", (unsigned long long)E.lost_pages);

	T_case = "a lost page: ticks over the hole do not accrue, held time resumes at the next real event";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	TICK(2 * MS);
	LOSS(3 * MS, 0);
	TICK(30 * MS);
	SW(0, 40 * MS, 0, HOST2, 0);
	SW(0, 42 * MS, HOST2, T1, 0);
	SW(0, 43 * MS, T1, 0, 0);
	TICK(50 * MS);
	EXPECT(CA, P_APP T_UI "d 2000 2000 1000000 2000000 1000000 1\nd 2000 2000 40000000 42000000 2000000 1\nc 2000 1 1\n");

	T_case = "a lost page with no pre-hole settle leaves no record";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 1 * MS, T1, 0);
	LOSS(3 * MS, 0);
	SW(0, 6 * MS, HOST1, T1, 0);
	SW(0, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP "c 2000 1 0\n");

	T_case = "a fork that purges the task table does not touch the freed parent";
	world(1);
	get_task(&E, HOST3);
	E.ntasks = TASK_CAP + 100;
	FK(0, HOST3, 1600);
	CHECK(E.ntasks <= TASK_CAP + 100, "the purge ran");

	T_case = "fork of an already-exited child of a host process that setns()ed into a sandbox";
	world(1);
	fp_find(HOST1)->ino_children = NS_A;
	SW(0, 0, 0, T2, 0);
	FK(0, HOST1, 1600);
	WK(K_WAKING, 1 * MS, T1, 0);
	SW(0, 2 * MS, T2, 1600, 0);
	SW(0, 6 * MS, 1600, T1, 0);
	SW(0, 7 * MS, T1, 0, 0);
	TICK(10 * MS);
	EXPECT(CA, P_APP "c 2000 2 0\n");

	T_case = "packets stay within 4096 bytes and end on a line";
	world(1);
	SW(0, 0, 0, HOST1, 0);
	WK(K_WAKING, 0, T1, 0);
	for (u64 k = 0; k < 300; k++) {
		SW(0, (2 * k + 1) * MS, HOST1, T1, 0);
		SW(0, (2 * k + 2) * MS, T1, HOST1, 1);
	}
	SW(0, 601 * MS, HOST1, T1, 0);
	SW(0, 602 * MS, T1, 0, 0);
	TICK(700 * MS);
	{
		const char *got = collect(CA);
		int d = 0;
		for (const char *l = got; (l = strstr(l, "\nd 2000 2000 ")) != NULL; l++)
			d++;
		CHECK(!strncmp(got, P_APP T_UI "d ", strlen(P_APP T_UI) + 2), "p and t come before the first d");
		CHECK(d == 301, "301 records, got %d", d);
		CHECK(OB_PKTS >= 4, "%d packets for ~14 KB", OB_PKTS);
	}
}

// test sandbox discovery from the fake process table
static void test_membership(void)
{
	T_case = "sandbox discovery";
	world(1);
	int n = 0;
	for (struct sbx *s = E.sbs; s; s = s->next)
		n += s->alive;
	CHECK(n == 2 && SA && SB, "two sandboxes (init context at pid 1), got %d", n);
	CHECK(!sbx_find(&E, NS_C), "a container whose pid 1 is not u:r:init:s0 is not a sandbox");
	CHECK(!sbx_find(&E, HOSTNS), "the host namespace is not a sandbox");
	CHECK(SA->nthreads == 5 && SB->nthreads == 2, "threads pre-registered: A=%d B=%d", SA->nthreads, SB->nthreads);

	T_case = "a sandbox that starts later is found and its cached tasks promoted";
	fp_add(1800, 1800, NS_D, 4000, 4000, "late", "late.app", "u:r:untrusted_app:s0", 1);
	struct task *t = get_task(&E, 1800);
	CHECK(t->sb == NULL && E.rescan_wanted, "an unclassified namespace is host for now and asks for a rescan");
	fp_add(700, 700, NS_D, 1, 1, "init", "/system/bin/init", INIT_CTX, 1);
	eng_rescan(&E);
	CHECK(sbx_find(&E, NS_D) && task_find(&E, 1800)->sb == sbx_find(&E, NS_D), "the cached task joined its sandbox");
	CHECK(!E.rescan_wanted, "rescan request cleared");
	fp_find(700)->alive = 0;
	fp_find(1800)->alive = 0;
	eng_rescan(&E);
	CHECK(!sbx_find(&E, NS_D), "a sandbox with no process left is gone");

	T_case = "peer check";
	fp_add(1200, 1200, NS_A, 3500, 3500, "hostdelay", "rhizo-host-delay", HOST_DELAY_CTX, 1);
	fp_add(1201, 1201, NS_A, 3501, 3501, "app", "app", "u:r:untrusted_app:s0", 1);
	fp_add(7010, 7010, HOSTNS, 7010, 7010, "imposter", "imposter", HOST_DELAY_CTX, 1);
	fp_add(1300, 1300, NS_C, 9, 9, "ctr", "ctr", HOST_DELAY_CTX, 1);
	fp_add(1710, 1710, NS_B, 3510, 3510, "hostdelay", "rhizo-host-delay", HOST_DELAY_CTX, 1);
	CHECK(peer_sandbox(&E, 1200) == SA, "the right domain in sandbox A is accepted as A");
	CHECK(peer_sandbox(&E, 1710) == SB, "the right domain in sandbox B is accepted as B");
	CHECK(peer_sandbox(&E, 1201) == NULL, "another domain in a sandbox is refused");
	CHECK(peer_sandbox(&E, 7010) == NULL, "the right domain on the host is refused");
	CHECK(peer_sandbox(&E, 1300) == NULL, "the right domain in a non-sandbox namespace is refused");
	CHECK(peer_sandbox(&E, 424242) == NULL, "a pid that is gone is refused");
	fp_add(710, 710, NS_D, 1, 1, "init", "/system/bin/init", INIT_CTX, 1);
	fp_add(1810, 1810, NS_D, 3600, 3600, "hostdelay", "rhizo-host-delay", HOST_DELAY_CTX, 1);
	CHECK(!sbx_find(&E, NS_D) && peer_sandbox(&E, 1810) == sbx_find(&E, NS_D) && sbx_find(&E, NS_D),
	      "a dialer from a sandbox born since the last scan is found by an on-demand scan");

	T_case = "watermark merge";
	world(1);
	struct evq q[2];
	memset(q, 0, sizeof q);
	static const u64 t0[] = { 1, 4, 9 }, t1[] = { 2, 3, 10 };
	for (int i = 0; i < 3; i++) {
		struct ev a = { t0[i] * MS, HOST3, 0, 0, 0, K_WAKING, 0 }, b = { t1[i] * MS, HOST3, 1, 0, 0, K_WAKING, 1 };
		evq_push(&q[0], &a);
		evq_push(&q[1], &b);
	}
	u64 done = merge_run(&E, q, 2, watermark(10 * MS));
	CHECK(done == 4 && E.late == 0 && q[0].n == 1 && q[1].n == 1, "five ms behind now: processed %llu, late %llu, queued %zu/%zu",
	      (unsigned long long)done, (unsigned long long)E.late, q[0].n, q[1].n);
	done = merge_run(&E, q, 2, 20 * MS);
	CHECK(done == 2 && E.late == 0 && E.now == 10 * MS, "the rest in order: %llu, late %llu", (unsigned long long)done,
	      (unsigned long long)E.late);
	CHECK(watermark(10 * MS) == 5 * MS && watermark(1 * MS) == 0, "watermark is now - 5 ms");
	free(q[0].v);
	free(q[1].v);
}

// return whether a text contains a string
static int disclosed(const char *text, const char *needle)
{
	return strstr(text, needle) != NULL;
}

// return whether a text contains a token as a whole word
static int token_in(const char *text, const char *tok)
{
	size_t l = strlen(tok);
	for (const char *p = text; *p;) {
		const char *s = p;
		while (*p && *p != ' ' && *p != '\n')
			p++;
		if ((size_t)(p - s) == l && !strncmp(s, tok, l))
			return 1;
		while (*p == ' ' || *p == '\n')
			p++;
	}
	return 0;
}

// search the output for host ids
static void test_disclosure(void)
{
	T_case = "disclosure: no holder comm or host pid in any output";
	CHECK(strlen(ALLOUT) > 1000, "scenarios produced %zu bytes of output to search", strlen(ALLOUT));
	CHECK(!disclosed(ALLOUT, "HOSTSECRET") && !disclosed(ALLOUT, "rt-load") && !disclosed(ALLOUT, "kworker"),
	      "a holder's comm appears in protocol output");
	static const char *const host_ids[] = { "7001", "7002", "31337", "500", "600", "1000", "1001", "1002", "1100", "1500", "1700", "9999" };
	for (size_t i = 0; i < sizeof host_ids / sizeof host_ids[0]; i++)
		CHECK(!token_in(ALLOUT, host_ids[i]), "host id %s appears as a protocol field", host_ids[i]);
	int bad = 0;
	for (const char *l = ALLOUT; *l;) {
		const char *e = strchr(l, '\n');
		if (!e)
			break;
		char kind = *l;
		int fields = 1;
		for (const char *p = l; p < e; p++)
			if (*p == ' ')
				fields++;
		int want = kind == 'p' ? 3 : kind == 't' ? 4 : kind == 'd' ? 7 : kind == 'c' ? 4 : kind == 'x' ? 2 : -1;
		if (fields != want || l[1] != ' ')
			bad++;
		l = e + 1;
	}
	CHECK(bad == 0, "%d protocol lines of the wrong shape", bad);

	T_case = "status.json is host-side counts only";
	char buf[4096];
	struct decode_stats ds;
	memset(&ds, 0, sizeof ds);
	world(1);
	LOSS(1 * MS, 0);
	int n = status_build(&E, &ds, 1, buf, sizeof buf);
	CHECK(n > 0 && buf[0] == '{' && strstr(buf, "\"lost_pages\":1") && strstr(buf, "\"connections\":1") &&
	      strstr(buf, "\"threads\":5") && !disclosed(buf, "HOSTSECRET"), "status: %s", buf);
}

// write text to a new file and return 0 on success
static int selftest_file(const char *path, const char *text)
{
	FILE *f = fopen(path, "we");
	if (!f)
		return -1;
	int bad = fputs(text, f) < 0;
	return fclose(f) || bad ? -1 : 0;
}

// test enter_domain's marker for each recorded selinux mode
static void test_domain(void)
{
	T_case = "domain";
	char dir[] = "/tmp/rhizo-delayd-selftest-XXXXXX";
	if (!mkdtemp(dir)) {
		CHECK(0, "mkdtemp %s: %s", dir, strerror(errno));
		return;
	}
	char mode[64], cur[64], logpath[64], out[512];
	snprintf(mode, sizeof mode, "%s/mode", dir);
	snprintf(cur, sizeof cur, "%s/current", dir);
	snprintf(logpath, sizeof logpath, "%s/log", dir);
	CHECK(selftest_file(cur, "kernel") == 0, "write %s: %s", cur, strerror(errno));
	const char *fs = g_selinuxfs, *attr = g_attr_current;
	g_selinuxfs = dir;
	g_attr_current = cur;
	setenv("RHIZO_SELINUX_MODE_FILE", mode, 1);
	static const struct {
		const char *text, *want;
		int refuse;
	} C[] = {
		{ "namespace\n", "delayd_domain state=no-selinux mode=namespace", 0 },
		{ "host\n", "delayd_domain state=deferred", 0 },
		{ "namespaces\n", "delayd_domain failed reason=selinux-mode", 1 },
		{ "namespace junk\n", "delayd_domain failed reason=selinux-mode", 1 },
		{ "host \n", "delayd_domain failed reason=selinux-mode", 1 },
		{ "", "delayd_domain failed reason=selinux-mode", 1 },
		{ NULL, "delayd_domain failed reason=selinux-mode", 1 },
	};
	static char name[] = "rhizo-delayd";
	char *argv[] = { name, NULL };
	for (size_t i = 0; i < sizeof C / sizeof C[0]; i++) {
		unlink(mode);
		if (C[i].text)
			CHECK(selftest_file(mode, C[i].text) == 0, "write %s: %s", mode, strerror(errno));
		int saved = dup(2), fd = open(logpath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
		CHECK(saved >= 0 && fd >= 0 && dup2(fd, 2) == 2, "redirect stderr to %s: %s", logpath, strerror(errno));
		close(fd);
		g_quiet = 0;
		int status = 0;
		if (C[i].refuse) {
			pid_t pid = fork();
			if (pid == 0) {
				enter_domain(argv, 0);
				_exit(0);
			}
			CHECK(pid > 0 && waitpid(pid, &status, 0) == pid, "fork: %s", strerror(errno));
		} else {
			enter_domain(argv, 0);
		}
		g_quiet = 1;
		fflush(stderr);
		dup2(saved, 2);
		close(saved);
		if (read_text(logpath, out, sizeof out) < 0)
			out[0] = 0;
		CHECK(strstr(out, C[i].want) != NULL, "mode file %s: want '%s', logged '%s'",
		      C[i].text ? C[i].text : "absent", C[i].want, out);
		if (C[i].refuse)
			CHECK(WIFEXITED(status) && WEXITSTATUS(status) == SELINUX_MODE_EXIT, "mode file %s: the start went on (status %d)",
			      C[i].text ? C[i].text : "absent", status);
	}
	unsetenv("RHIZO_SELINUX_MODE_FILE");
	g_selinuxfs = fs;
	g_attr_current = attr;
	unlink(mode);
	unlink(cur);
	unlink(logpath);
	rmdir(dir);
}

// run all of the self-test groups and return the failure count
static int selftest(void)
{
	g_quiet = 1;
	test_decoder();
	test_scenarios();
	test_membership();
	test_disclosure();
	test_domain();
	if (T_fail) {
		fprintf(stderr, "rhizo-delayd selftest: %d of %d assertions FAILED\n", T_fail, T_fail + T_pass);
		return 1;
	}
	printf("rhizo-delayd selftest: %d assertions passed\n", T_pass);
	return 0;
}

static void usage(void)
{
	fputs("usage: rhizo-delayd [--socket PATH] [--status-path PATH] [--tracefs DIR] [--instance NAME]\n"
	      "                    [--buffer-kb N] | --selftest | --dump-events SECONDS | --remove-instance\n", stderr);
}

// run rhizo-delayd
int main(int argc, char **argv)
{
	struct cfg cfg = { "/run/rhizo-delay/delayd", "/run/rhizo-delayd/status.json", NULL, "rhizo-delay", 8192, 0, 0, 0 };
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		int has = i + 1 < argc;
		if (!strcmp(a, "--selftest"))
			cfg.selftest = 1;
		else if (!strcmp(a, "--socket") && has)
			cfg.socket_path = argv[++i];
		else if (!strcmp(a, "--status-path") && has)
			cfg.status_path = argv[++i];
		else if (!strcmp(a, "--tracefs") && has)
			cfg.tracefs = argv[++i];
		else if (!strcmp(a, "--instance") && has)
			cfg.instance = argv[++i];
		else if (!strcmp(a, "--buffer-kb") && has)
			cfg.buffer_kb = atoi(argv[++i]);
		else if (!strcmp(a, "--remove-instance"))
			cfg.remove_instance = 1;
		else if (!strcmp(a, "--dump-events") && has)
			cfg.dump_secs = atoi(argv[++i]);
		else {
			usage();
			return 2;
		}
	}
	if (cfg.selftest)
		return selftest();
	if (cfg.buffer_kb <= 0 || (cfg.dump_secs < 0)) {
		usage();
		return 2;
	}
	if (cfg.dump_secs > 0)
		return run_dump(&cfg);
	enter_domain(argv, cfg.remove_instance);
	if (cfg.remove_instance)
		return run_remove_instance(&cfg);
	return run_daemon(&cfg);
}
