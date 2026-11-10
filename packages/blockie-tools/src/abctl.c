#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define BLOCK 4096
#define SECTOR 512
#define MSG_SIZE 2048
#define FIELD 32
#define STATUS_OFF 32
#define RECOVERY_OFF 64
#define REFRESH_OFF 448
#define EMPTY 3
#define WRITE_FAILED 4
#define BC_OFF 0x800
#define BC_SIZE 32
#define BC_MAGIC 0x42414342u
#define OURS "recovery\n--blockie="

struct slot {
    int priority;
    int tries;
    int successful;
    int verity;
};

static const char* dev = "/dev/block/by-name/misc";
static int attempt;

static const char* const writes[] = { "default-a", "hold-b", "fix-b", "unprove-b", "refund-a", "test-b", "arm-a",
                                      "arm-b-once", "rearm", "bcb-recovery", "bcb-attempt", "bcb-input", "bcb-refresh",
                                      "bcb-clear", "clear-msg", "restore", NULL };

static void usage(void)
{
    fprintf(stderr, "usage: abctl [-d device] [-o offset] show\n"
                    "       abctl [-d device] default-a | hold-b | fix-b | unprove-b | refund-a | test-b\n"
                    "       abctl [-d device] arm-a | arm-b-once | rearm | clear-msg | restore <file>\n"
                    "       abctl [-d device] bcb-recovery <reason> | bcb-attempt | bcb-input | bcb-refresh <cap>\n"
                    "       abctl [-d device] bcb-clear\n");
    exit(2);
}

static uint32_t get32(const uint8_t* p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void put32(uint8_t* p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static uint32_t crc32(const uint8_t* p, size_t n)
{
    uint32_t c = 0xffffffffu;
    while (n--) {
        c ^= *p++;
        for (int k = 0; k < 8; k++)
            c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1u)));
    }
    return ~c;
}

static struct slot get_slot(const uint8_t* bc, int i)
{
    const uint8_t* s = bc + 12 + 2 * i;
    struct slot r = { s[0] & 15, s[0] >> 4 & 7, s[0] >> 7, s[1] & 1 };
    return r;
}

static void set_slot(uint8_t* bc, int i, struct slot v)
{
    uint8_t* s = bc + 12 + 2 * i;
    s[0] = (uint8_t)(v.priority | v.tries << 4 | v.successful << 7);
    s[1] = (uint8_t)v.verity;
}

static int bootable(struct slot s)
{
    return s.priority > 0 && (s.tries > 0 || s.successful);
}

static int full(struct slot s)
{
    return s.priority == 15 && s.tries == 3 && !s.successful;
}

static int crc_ok(const uint8_t* bc)
{
    return get32(bc + 28) == crc32(bc, 28);
}

static int valid(const uint8_t* bc)
{
    return get32(bc + 4) == BC_MAGIC && bc[8] == 1 && (bc[9] & 7) == 2 && crc_ok(bc);
}

static const char* block_class(const uint8_t* bc)
{
    struct slot a = get_slot(bc, 0);
    struct slot b = get_slot(bc, 1);
    if (!valid(bc))
        return "invalid";
    return a.priority == b.priority || a.tries > 3 ? "reset" : "ours";
}

static void print_slot(const uint8_t* bc, int i)
{
    struct slot s = get_slot(bc, i);
    printf("slot %c priority %d tries %d successful %d verity_corrupted %d %s\n", 'a' + i, s.priority, s.tries,
           s.successful, s.verity, bootable(s) ? "bootable" : "unbootable");
}

static void print_bc(const uint8_t* bc)
{
    printf("suffix %.*s\n", (int)strnlen((const char*)bc, 4), (const char*)bc);
    printf("magic 0x%08x %s\n", get32(bc + 4), get32(bc + 4) == BC_MAGIC ? "ok" : "bad");
    printf("version %u\n", bc[8]);
    printf("nb_slot %u\n", bc[9] & 7);
    printf("recovery_tries %u\n", bc[9] >> 3 & 7);
    printf("merge_status %u\n", (bc[9] >> 6 | (bc[10] & 1) << 2) & 7);
    printf("crc32 0x%08x %s\n", get32(bc + 28), crc_ok(bc) ? "ok" : "bad");
    print_slot(bc, 0);
    print_slot(bc, 1);
    printf("class %s\n", block_class(bc));
}

static size_t reason_len(const uint8_t* msg)
{
    const uint8_t* r = msg + RECOVERY_OFF + strlen(OURS);
    size_t n = 0;
    if (memcmp(msg, "boot-recovery", 14) || memcmp(msg + RECOVERY_OFF, OURS, strlen(OURS)))
        return 0;
    while (n <= FIELD && ((r[n] >= 'a' && r[n] <= 'z') || (r[n] >= '0' && r[n] <= '9') || r[n] == '_'))
        n++;
    return n && n <= FIELD && !r[n] ? n : 0;
}

static int is_count(const uint8_t* s, const char* key, int n)
{
    char want[FIELD] = { 0 };
    if (n)
        snprintf(want, sizeof want, "%s=%d", key, n);
    return !memcmp(s, want, FIELD);
}

static int refreshes(const uint8_t* msg)
{
    for (int n = 0; n < 100; n++)
        if (is_count(msg + REFRESH_OFF, "blockie-refresh", n))
            return n;
    return -1;
}

static void print_escaped(const uint8_t* s, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (s[i] < 0x20 || s[i] > 0x7e || s[i] == '"' || s[i] == '\\')
            printf("\\x%02x", s[i]);
        else
            putchar(s[i]);
    }
}

static void print_msg(const uint8_t* msg)
{
    int n;
    size_t i = 0;
    while (i < MSG_SIZE && !msg[i])
        i++;
    if (i == MSG_SIZE) {
        printf("message zero\n");
        return;
    }
    printf("message command \"");
    print_escaped(msg, strnlen((const char*)msg, 32));
    printf("\"\n");
    if ((i = reason_len(msg))) {
        printf("message reason ");
        print_escaped(msg + RECOVERY_OFF + strlen(OURS), i);
        printf("\n");
    }
    if ((n = refreshes(msg)) > 0)
        printf("message refresh %d\n", n);
}

static int read_at(int fd, const char* name, void* buf, size_t n, long off, const char* what)
{
    ssize_t r = pread(fd, buf, n, off);
    if (r == (ssize_t)n)
        return 0;
    if (r < 0)
        fprintf(stderr, "abctl: %s: %s at 0x%lx: %s\n", name, what, off, strerror(errno));
    else
        fprintf(stderr, "abctl: %s: %s at 0x%lx: got %zd of %zu bytes\n", name, what, off, r, n);
    return 1;
}

static int openable(const char* path)
{
    struct stat st;
    if (stat(path, &st)) {
        fprintf(stderr, "abctl: %s: %s\n", path, strerror(errno));
        return 0;
    }
    if (!S_ISREG(st.st_mode) && !S_ISBLK(st.st_mode)) {
        fprintf(stderr, "abctl: %s: neither a block device nor a file, not opened\n", path);
        return 0;
    }
    return 1;
}

static int show(long off)
{
    uint8_t buf[MSG_SIZE];
    uint8_t bc[BC_SIZE];
    if (!openable(dev))
        return 1;
    int fd = open(dev, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "abctl: %s: %s\n", dev, strerror(errno));
        return 1;
    }
    if (read_at(fd, dev, bc, BC_SIZE, off, "read")) {
        close(fd);
        return 1;
    }
    print_bc(bc);
    if (off == BC_OFF) {
        if (read_at(fd, dev, buf, MSG_SIZE, 0, "read")) {
            close(fd);
            return 1;
        }
        print_msg(buf);
    }
    close(fd);
    printf("bproof 1\n");
    return valid(bc) ? 0 : 1;
}

static void set_suffix(uint8_t* bc, char slot)
{
    bc[0] = '_';
    bc[1] = (uint8_t)slot;
    bc[2] = 0;
    bc[3] = 0;
}

static int rules(const char* cmd, const uint8_t* old, const uint8_t* bc)
{
    struct slot a0 = get_slot(old, 0);
    struct slot b0 = get_slot(old, 1);
    struct slot a = get_slot(bc, 0);
    struct slot b = get_slot(bc, 1);
    if (!strcmp(cmd, "fix-b")) {
        if (bootable(b0)) {
            fprintf(stderr, "abctl: fix-b refused: slot b reads bootable\n");
            return 1;
        }
        if (!bootable(b) || memcmp(old + 12, bc + 12, 2)) {
            fprintf(stderr, "abctl: fix-b refused: result has slot b unbootable or slot a changed\n");
            return 1;
        }
    } else if (!bootable(a) || !bootable(b)) {
        fprintf(stderr, "abctl: %s refused: result has slot a %s and slot b %s\n", cmd,
                bootable(a) ? "bootable" : "unbootable", bootable(b) ? "bootable" : "unbootable");
        return 1;
    }
    if (a.priority == b.priority) {
        fprintf(stderr, "abctl: %s refused: result has both slots at priority %d\n", cmd, a.priority);
        return 1;
    }
    if (!strcmp(cmd, "refund-a") && (a0.priority != 15 || a0.successful || b0.priority != 13)) {
        fprintf(stderr, "abctl: refund-a refused: needs slot a priority 15 successful 0 and slot b priority 13, reads "
                        "a %d/%d/%d b %d/%d/%d\n", a0.priority, a0.tries, a0.successful, b0.priority, b0.tries,
                b0.successful);
        return 1;
    }
    if ((!strcmp(cmd, "test-b") || !strcmp(cmd, "unprove-b")) && !full(a0)) {
        fprintf(stderr, "abctl: %s refused: slot a reads %d/%d/%d, not 15/3/0\n", cmd, a0.priority, a0.tries,
                a0.successful);
        return 1;
    }
    if ((!strcmp(cmd, "hold-b") || !strcmp(cmd, "arm-b-once")) && (!bootable(a0) || !a0.tries)) {
        fprintf(stderr, "abctl: %s refused: slot a reads %d/%d/%d, not bootable with tries left\n", cmd, a0.priority,
                a0.tries, a0.successful);
        return 1;
    }
    if (!strcmp(cmd, "hold-b") && !b0.successful && !full(a0)) {
        fprintf(stderr, "abctl: hold-b refused: slot b reads successful 0 and slot a reads %d/%d/%d, not 15/3/0\n",
                a0.priority, a0.tries, a0.successful);
        return 1;
    }
    return 0;
}

static int count(const char* cmd, uint8_t* blk, const char* arg)
{
    uint8_t* status = blk + STATUS_OFF;
    int n = 0;
    if (!blk[0]) {
        fprintf(stderr, "abctl: %s: no command in the bootloader message, nothing written\n", cmd);
        return EMPTY;
    }
    if (!strcmp(cmd, "bcb-input")) {
        memset(status, 0, FIELD);
        return 0;
    }
    if (!strcmp(cmd, "bcb-refresh")) {
        int cap = atoi(arg);
        if (!reason_len(blk)) {
            fprintf(stderr, "abctl: bcb-refresh refused: the bootloader message is not ours\n");
            return 1;
        }
        if ((n = refreshes(blk)) < 0) {
            fprintf(stderr, "abctl: bcb-refresh refused: the counter at misc+%d does not parse, counted as the cap\n",
                    REFRESH_OFF);
            return 1;
        }
        if (n >= cap) {
            fprintf(stderr, "abctl: bcb-refresh refused: blockie-refresh=%d, the cap is %d\n", n, cap);
            return 1;
        }
        memset(blk + REFRESH_OFF, 0, FIELD);
        snprintf((char*)blk + REFRESH_OFF, FIELD, "blockie-refresh=%d", n + 1);
        return 0;
    }
    while (n < 3 && !is_count(status, "blockie-attempt", n))
        n++;
    if (n == 3)
        fprintf(stderr, "abctl: bcb-attempt: status neither empty nor blockie-attempt=1 or 2, counted as the bound\n");
    attempt = n < 3 ? n + 1 : 3;
    memset(status, 0, FIELD);
    snprintf((char*)status, FIELD, "blockie-attempt=%d", attempt);
    return 0;
}

static int change(const char* cmd, uint8_t* blk, uint8_t* file, const char* arg)
{
    uint8_t* bc = blk + BC_OFF;
    if (!strcmp(cmd, "restore")) {
        uint8_t* src = file + BC_OFF;
        if (!valid(src)) {
            fprintf(stderr, "abctl: restore refused: no valid bootloader_control at 0x%x in the file\n", BC_OFF);
            return 1;
        }
        if (get_slot(src, 1).successful && !(valid(bc) && get_slot(bc, 1).successful)) {
            src[14] &= 0x7f;
            put32(src + 28, crc32(src, 28));
        }
        if (memcmp(bc, src, BC_SIZE) && rules(cmd, bc, src))
            return 1;
        memcpy(blk, file, BLOCK);
        return 0;
    }
    if (!strcmp(cmd, "clear-msg") || !strncmp(cmd, "bcb-", 4)) {
        if (get32(bc + 4) != BC_MAGIC) {
            fprintf(stderr, "abctl: %s: %s refused: no bootloader_control magic at 0x%x\n", dev, cmd, BC_OFF + 4);
            return 1;
        }
        if (!strcmp(cmd, "clear-msg")) {
            memset(blk, 0, MSG_SIZE);
        } else if (!strcmp(cmd, "bcb-clear")) {
            memset(blk, 0, SECTOR);
        } else if (!strcmp(cmd, "bcb-recovery")) {
            memset(blk, 0, SECTOR);
            memcpy(blk, "boot-recovery", 13);
            snprintf((char*)blk + RECOVERY_OFF, SECTOR - RECOVERY_OFF, OURS "%s", arg);
        } else {
            return count(cmd, blk, arg);
        }
        return 0;
    }
    if (!valid(bc)) {
        fprintf(stderr, "abctl: %s: no valid bootloader_control at 0x%x\n", dev, BC_OFF);
        return 1;
    }
    uint8_t old[BC_SIZE];
    memcpy(old, bc, BC_SIZE);
    struct slot a = get_slot(bc, 0);
    struct slot b = get_slot(bc, 1);
    if (!strcmp(cmd, "default-a")) {
        a = (struct slot){ 15, 3, 0, a.verity };
        b = (struct slot){ 13, 1, b.successful, b.verity };
        set_suffix(bc, 'a');
    } else if (!strcmp(cmd, "hold-b")) {
        a = (struct slot){ 14, a.tries, 0, a.verity };
        b = (struct slot){ 15, 1, b.successful, b.verity };
        set_suffix(bc, 'b');
    } else if (!strcmp(cmd, "fix-b")) {
        b = (struct slot){ 13, 1, 0, b.verity };
    } else if (!strcmp(cmd, "unprove-b")) {
        b = (struct slot){ 13, 1, 0, b.verity };
    } else if (!strcmp(cmd, "refund-a")) {
        a.tries = a.tries < 3 ? a.tries + 1 : 3;
        b.priority = 12;
    } else if (!strcmp(cmd, "arm-a")) {
        a = (struct slot){ 15, 1, 0, a.verity };
        b = (struct slot){ 14, 1, b.successful, b.verity };
        set_suffix(bc, 'a');
    } else if (!strcmp(cmd, "arm-b-once") || !strcmp(cmd, "test-b")) {
        a.priority = 14;
        b = (struct slot){ 15, 1, 0, b.verity };
        set_suffix(bc, 'b');
    } else {
        a = (struct slot){ 15, 3, 0, a.verity };
        set_suffix(bc, 'a');
    }
    if (strcmp(cmd, "fix-b") && strcmp(cmd, "unprove-b"))
        set_slot(bc, 0, a);
    set_slot(bc, 1, b);
    if (rules(cmd, old, bc))
        return 1;
    bc[11] = 0;
    memset(bc + 20, 0, 8);
    put32(bc + 28, crc32(bc, 28));
    return 0;
}

static int misc_target(int fd)
{
    struct stat st;
    if (fstat(fd, &st)) {
        fprintf(stderr, "abctl: %s: %s\n", dev, strerror(errno));
        return 0;
    }
    if (S_ISREG(st.st_mode))
        return 1;
    if (!S_ISBLK(st.st_mode)) {
        fprintf(stderr, "abctl: %s: neither a block device nor a file\n", dev);
        return 0;
    }
    char path[64];
    char line[256];
    int ok = 0;
    snprintf(path, sizeof path, "/sys/dev/block/%u:%u/uevent", major(st.st_rdev), minor(st.st_rdev));
    FILE* f = fopen(path, "re");
    if (f) {
        while (fgets(line, sizeof line, f))
            if (!strcmp(line, "PARTNAME=misc\n"))
                ok = 1;
        fclose(f);
    }
    if (!ok)
        fprintf(stderr, "abctl: %s: not the misc partition (no PARTNAME=misc in %s)\n", dev, path);
    return ok;
}

static int load(const char* path, uint8_t* blk)
{
    if (!openable(path))
        return 1;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "abctl: %s: %s\n", path, strerror(errno));
        return 1;
    }
    int rc = read_at(fd, path, blk, BLOCK, 0, "read");
    close(fd);
    return rc;
}

static int lock(int fd)
{
    for (int i = 0; i < 50; i++) {
        if (!flock(fd, LOCK_EX | LOCK_NB))
            return 1;
        if (errno != EWOULDBLOCK) {
            fprintf(stderr, "abctl: %s: flock: %s\n", dev, strerror(errno));
            return 0;
        }
        usleep(100000);
    }
    fprintf(stderr, "abctl: misc busy\n");
    return 0;
}

static int update(const char* cmd, const char* arg)
{
    uint8_t* blk;
    uint8_t* back;
    uint8_t* file = NULL;
    const char* path = strcmp(cmd, "restore") ? NULL : arg;
    long off = 0;
    size_t len = BLOCK;
    int rc = 1;
    int r;
    ssize_t w;
    if (!strcmp(cmd, "clear-msg")) {
        len = MSG_SIZE;
    } else if (strcmp(cmd, "restore")) {
        off = strncmp(cmd, "bcb-", 4) ? BC_OFF : 0;
        len = SECTOR;
    }
    if (posix_memalign((void**)&blk, BLOCK, BLOCK) || posix_memalign((void**)&back, BLOCK, BLOCK) ||
        (path && !(file = malloc(BLOCK)))) {
        fprintf(stderr, "abctl: out of memory\n");
        return 1;
    }
    if ((path && load(path, file)) || !openable(dev))
        return 1;
    int fd = open(dev, O_RDWR | O_DIRECT | O_SYNC | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "abctl: %s: %s\n", dev, strerror(errno));
        return 1;
    }
    if (!misc_target(fd) || !lock(fd) || read_at(fd, dev, blk, BLOCK, 0, "read"))
        goto out;
    r = change(cmd, blk, file, arg);
    if (r == EMPTY) {
        printf("empty\n");
        rc = EMPTY;
    }
    if (r)
        goto out;
    rc = WRITE_FAILED;
    w = pwrite(fd, blk + off, len, off);
    if (w < 0) {
        fprintf(stderr, "abctl: %s: write failed at 0x%lx: %s\n", dev, off, strerror(errno));
        goto out;
    }
    if (w != (ssize_t)len) {
        fprintf(stderr, "abctl: %s: write failed at 0x%lx: got %zd of %zu bytes\n", dev, off, w, len);
        goto out;
    }
    if (fsync(fd)) {
        fprintf(stderr, "abctl: %s: fsync failed: %s\n", dev, strerror(errno));
        goto out;
    }
    if (read_at(fd, dev, back, BLOCK, 0, "read back"))
        goto out;
    if (memcmp(blk, back, BLOCK)) {
        fprintf(stderr, "abctl: %s: read back differs from what was written\n", dev);
        goto out;
    }
    rc = 0;
    if (!strcmp(cmd, "bcb-attempt")) {
        printf("%d\n", attempt);
        goto out;
    }
    printf("%s: written and read back\n", cmd);
    print_bc(back + BC_OFF);
    print_msg(back);
out:
    close(fd);
    return rc;
}

int main(int argc, char** argv)
{
    long off = -1;
    int c;
    while ((c = getopt(argc, argv, "d:o:")) != -1) {
        if (c == 'd') {
            dev = optarg;
        } else if (c == 'o') {
            char* end;
            off = strtol(optarg, &end, 0);
            if (*end || off < 0)
                usage();
        } else {
            usage();
        }
    }
    if (optind >= argc)
        usage();
    const char* cmd = argv[optind];
    int takes_arg = !strcmp(cmd, "restore") || !strcmp(cmd, "bcb-recovery") || !strcmp(cmd, "bcb-refresh");
    if (argc - optind != 1 + takes_arg)
        usage();
    if (!strcmp(cmd, "show"))
        return show(off < 0 ? BC_OFF : off);
    if (off >= 0)
        usage();
    int known = 0;
    for (int i = 0; writes[i]; i++)
        known |= !strcmp(cmd, writes[i]);
    if (!known)
        usage();
    const char* arg = takes_arg ? argv[optind + 1] : NULL;
    if (!strcmp(cmd, "bcb-recovery")) {
        size_t n = strspn(arg, "abcdefghijklmnopqrstuvwxyz0123456789_");
        if (!n || n > FIELD || arg[n])
            usage();
    }
    if (!strcmp(cmd, "bcb-refresh")) {
        size_t n = strspn(arg, "0123456789");
        if (!n || n > 2 || arg[n] || !atoi(arg))
            usage();
    }
    return update(cmd, arg);
}
