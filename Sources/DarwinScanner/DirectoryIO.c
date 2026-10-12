/*
 * DarwinScanner C bridge implementation.
 *
 * Everything that requires knowledge of the kernel's getattrlistbulk record
 * layout, of errno, or of statfs lives here. The Swift layer only ever sees
 * fixed-size records.
 */

#include "DarwinScanner.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/unistd.h>
#include <unistd.h>

/* One getattrlistbulk buffer before it is grown. */
#define DARWIN_BULK_FIRST_BYTES (512u * 1024u)

/* Hard ceiling for the one-shot bulk read. Larger directories fall back to the
 * cursor, which has no such ceiling. */
#define DARWIN_BULK_MAX_BYTES (16u * 1024u * 1024u)

/*
 * Requested attributes.
 *
 * Kept deliberately small: every attribute added here is another field whose
 * position in the record must be exactly right.
 *
 * ATTR_CMN_RETURNED_ATTRS is mandatory for getattrlistbulk and always arrives
 * first, inline, as a 20 byte attribute_set_t. ATTR_CMN_OBJID is intentionally
 * not requested: it returns a fsobj_id_t, which is not a file id and must not
 * be passed off as st_ino. ATTR_CMN_ERROR is not requested either — a child
 * whose attributes were unavailable is detected from the returned attribute
 * set, which is authoritative.
 *
 * FSOPT_PACK_INVAL_ATTRS is deliberately NOT set. That option makes the kernel
 * emit placeholder slots for attributes a file cannot supply, which keeps the
 * record layout fixed but requires trusting that layout for every entry.
 * Without it the kernel simply omits them, and the returned attribute set says
 * exactly which fields are present — a layout that is checked rather than
 * assumed.
 */
#define DARWIN_BULK_COMMON_ATTRS                                             \
    (ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE |            \
     ATTR_CMN_MODTIME | ATTR_CMN_FILEID)

/* ATTR_DIR_MOUNTSTATUS */
#define DARWIN_BULK_DIR_ATTRS (ATTR_DIR_MOUNTSTATUS)

/* ATTR_FILE_DATALENGTH */
#define DARWIN_BULK_FILE_ATTRS (ATTR_FILE_DATALENGTH)

#define DARWIN_BULK_OPTIONS (FSOPT_REPORT_FULLSIZE)

/* Bytes of fixed header ahead of the first attribute: length + attr set. */
#define DARWIN_RECORD_HEADER_BYTES (4u + 20u)

/* ------------------------------------------------------------------ */
/* Bounds checked cursor                                               */
/* ------------------------------------------------------------------ */

typedef struct {
    const unsigned char *base;
    uint64_t limit; /* exclusive end of readable region */
    uint64_t cursor;
} darwin_cursor;

static void cursor_init(darwin_cursor *cursor, const unsigned char *base, uint64_t limit,
                        uint64_t start) {
    cursor->base = base;
    cursor->limit = limit;
    cursor->cursor = start;
}

/* Every field is read through this, so a truncated or misaligned record can
 * never produce an out-of-range access. Attributes are 4 byte aligned. */
static int cursor_take(darwin_cursor *cursor, uint64_t bytes, const unsigned char **out) {
    uint64_t start = (cursor->cursor + 3u) & ~((uint64_t)3u);
    if (start > cursor->limit || bytes > cursor->limit - start) {
        return -1;
    }
    cursor->cursor = start + bytes;
    if (out != NULL) {
        *out = cursor->base + start;
    }
    return 0;
}

static int cursor_read_u32(darwin_cursor *cursor, uint32_t *out) {
    const unsigned char *at = NULL;
    if (cursor_take(cursor, 4u, &at) != 0) {
        return -1;
    }
    memcpy(out, at, 4);
    return 0;
}

static int cursor_read_i32(darwin_cursor *cursor, int32_t *out) {
    uint32_t raw = 0;
    if (cursor_read_u32(cursor, &raw) != 0) {
        return -1;
    }
    memcpy(out, &raw, 4);
    return 0;
}

static int cursor_read_u64(darwin_cursor *cursor, uint64_t *out) {
    const unsigned char *at = NULL;
    if (cursor_take(cursor, 8u, &at) != 0) {
        return -1;
    }
    memcpy(out, at, 8);
    return 0;
}

/* struct timeval: 16 bytes, only tv_sec is kept. */
static int cursor_read_timeval(darwin_cursor *cursor, int64_t *out_seconds) {
    const unsigned char *at = NULL;
    if (cursor_take(cursor, 16u, &at) != 0) {
        return -1;
    }
    int64_t seconds = 0;
    memcpy(&seconds, at, 8);
    *out_seconds = seconds;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Strict UTF-8                                                        */
/* ------------------------------------------------------------------ */

/*
 * Rejects overlong encodings, surrogates and out-of-range code points, none of
 * which a lossy decoder would surface: a name that is not valid UTF-8 has no
 * faithful String form, so it must be dropped and reported rather than turned
 * into a plausible-looking path that points at nothing.
 *
 * Both readers apply this. Validating only the bulk reader would be useless:
 * the fallback would happily emit a replacement-character name for exactly the
 * files the bulk reader refused, and those are the names that silently point
 * at something that does not exist.
 */
int darwin_is_valid_utf8(const unsigned char *bytes, uint32_t length) {
    uint32_t index = 0;
    while (index < length) {
        unsigned char lead = bytes[index];
        if (lead < 0x80u) {
            index += 1u;
            continue;
        }
        uint32_t extra = 0;
        uint32_t code = 0;
        if ((lead & 0xE0u) == 0xC0u) {
            extra = 1u;
            code = lead & 0x1Fu;
        } else if ((lead & 0xF0u) == 0xE0u) {
            extra = 2u;
            code = lead & 0x0Fu;
        } else if ((lead & 0xF8u) == 0xF0u) {
            extra = 3u;
            code = lead & 0x07u;
        } else {
            return 0; /* continuation byte or 5/6 byte lead */
        }
        if (index + extra >= length) {
            return 0; /* truncated multi-byte sequence */
        }
        for (uint32_t step = 1; step <= extra; step++) {
            unsigned char continuation = bytes[index + step];
            if ((continuation & 0xC0u) != 0x80u) {
                return 0;
            }
            code = (code << 6) | (continuation & 0x3Fu);
        }
        if (extra == 1u && code < 0x80u) {
            return 0; /* overlong */
        }
        if (extra == 2u && code < 0x800u) {
            return 0;
        }
        if (extra == 3u && code < 0x10000u) {
            return 0;
        }
        if (code > 0x10FFFFu) {
            return 0;
        }
        if (code >= 0xD800u && code <= 0xDFFFu) {
            return 0; /* surrogate */
        }
        index += extra + 1u;
    }
    return 1;
}

/* ------------------------------------------------------------------ */
/* Record decoding                                                     */
/* ------------------------------------------------------------------ */

typedef enum {
    DARWIN_RECORD_OK = 0,
    /* Structurally impossible: offsets, lengths or the record chain did not
     * hold together. The whole buffer is unusable. */
    DARWIN_RECORD_BROKEN = -1,
    /* This child alone is unusable: dropped, but the rest of the directory is
     * still usable and still incomplete. */
    DARWIN_RECORD_REJECTED = 1
} darwin_record_status;

static void item_reject(darwin_bulk_item *item, uint32_t flags, uint32_t error) {
    memset(item, 0, sizeof(*item));
    item->flags = flags;
    item->error = error;
    item->name_length = 0u;
    item->name[0] = '\0';
}

/*
 * Decodes the record starting at `offset`.
 *
 * Layout: uint32 length, then the inline 20 byte attribute_set_t, then the
 * requested-and-returned attributes group by group, each 4 byte aligned.
 * ATTR_CMN_NAME is an attrreference_t whose offset is relative to the
 * reference itself.
 */
static darwin_record_status parse_record(const unsigned char *buffer, uint64_t available,
                                         uint64_t offset, darwin_bulk_item *item) {
    if (offset > available || available - offset < DARWIN_RECORD_HEADER_BYTES) {
        return DARWIN_RECORD_BROKEN;
    }

    darwin_cursor cursor;
    cursor_init(&cursor, buffer, available, offset);

    uint32_t length = 0;
    if (cursor_read_u32(&cursor, &length) != 0) {
        return DARWIN_RECORD_BROKEN;
    }
    /* length counts the whole record including this header. */
    if (length < DARWIN_RECORD_HEADER_BYTES || length > available - offset) {
        return DARWIN_RECORD_BROKEN;
    }
    const uint64_t record_start = offset;
    const uint64_t record_end = offset + length;

    attribute_set_t returned;
    memset(&returned, 0, sizeof(returned));
    if (cursor_read_u32(&cursor, &returned.commonattr) != 0 ||
        cursor_read_u32(&cursor, &returned.volattr) != 0 ||
        cursor_read_u32(&cursor, &returned.dirattr) != 0 ||
        cursor_read_u32(&cursor, &returned.fileattr) != 0 ||
        cursor_read_u32(&cursor, &returned.forkattr) != 0) {
        return DARWIN_RECORD_BROKEN;
    }

    memset(item, 0, sizeof(*item));
    item->returned_attrs = returned.commonattr;

    /* The reference must live inside this record, or the record is nonsense. */
    const uint64_t record_limit = record_end < available ? record_end : available;
    cursor.limit = record_limit;

    /* ATTR_CMN_NAME: an attrreference_t, offset relative to itself. */
    if (returned.commonattr & ATTR_CMN_NAME) {
        const uint64_t reference_start = cursor.cursor;
        int32_t name_offset = 0;
        uint32_t name_length = 0;
        if (cursor_read_i32(&cursor, &name_offset) != 0 ||
            cursor_read_u32(&cursor, &name_length) != 0) {
            return DARWIN_RECORD_BROKEN;
        }
        if (name_offset < 0 || name_length == 0u || name_length >= sizeof(item->name)) {
            return DARWIN_RECORD_BROKEN;
        }
        uint64_t name_position = reference_start + (uint64_t)name_offset;
        if (name_position < record_start || name_position > record_limit ||
            name_length > record_limit - name_position) {
            return DARWIN_RECORD_BROKEN;
        }
        const unsigned char *name_bytes = buffer + name_position;
        // attr_length includes the terminating NUL; our POD length excludes it.
        if (name_bytes[name_length - 1u] != 0u) { return DARWIN_RECORD_BROKEN; }
        name_length--;
        for (uint32_t index = 0; index < name_length; index++) {
            if (name_bytes[index] == 0u) {
                return DARWIN_RECORD_BROKEN;
            }
        }
        if (!darwin_is_valid_utf8(name_bytes, name_length)) {
            /* A name with no faithful String form is dropped outright. The
             * record is not invented into a replacement-character path, and the
             * listing is marked incomplete so nothing is pruned on its
             * strength. */
            item_reject(item, DARWIN_ITEM_UTF8_REJECTED | DARWIN_ITEM_STAT_FAILED, EILSEQ);
            return DARWIN_RECORD_REJECTED;
        }
        memcpy(item->name, name_bytes, name_length);
        item->name[name_length] = '\0';
        item->name_length = name_length;
    }

    if (returned.commonattr & ATTR_CMN_OBJTYPE) {
        if (cursor_read_u32(&cursor, &item->object_type) != 0) {
            return DARWIN_RECORD_BROKEN;
        }
    }
    if (returned.commonattr & ATTR_CMN_MODTIME) {
        if (cursor_read_timeval(&cursor, &item->modified_at) != 0) {
            return DARWIN_RECORD_BROKEN;
        }
    }
    if (returned.commonattr & ATTR_CMN_FILEID) {
        if (cursor_read_u64(&cursor, &item->file_id) != 0) {
            return DARWIN_RECORD_BROKEN;
        }
    }

    if (returned.dirattr & ATTR_DIR_MOUNTSTATUS) {
        uint32_t mount_status = 0;
        if (cursor_read_u32(&cursor, &mount_status) != 0) {
            return DARWIN_RECORD_BROKEN;
        }
        if ((mount_status & DIR_MNTSTATUS_MNTPOINT) != 0u) {
            item->flags |= DARWIN_ITEM_IS_MOUNT_POINT;
        }
    }
    if (returned.fileattr & ATTR_FILE_DATALENGTH) {
        if (cursor_read_u64(&cursor, (uint64_t *)&item->size) != 0) {
            return DARWIN_RECORD_BROKEN;
        }
    }

    if (item->object_type != DARWIN_VREG) { item->size = 0; }
    if (cursor.cursor > record_limit) {
        return DARWIN_RECORD_BROKEN;
    }

    /*
     * A record that never produced a usable name, or whose type the kernel
     * could not state, is a child we cannot index. It is still counted so the
     * listing is reported incomplete.
     */
    if (item->name_length == 0u || (returned.commonattr & ATTR_CMN_OBJTYPE) == 0u) {
        item->flags |= DARWIN_ITEM_STAT_FAILED;
        if (item->error == 0u) {
            item->error = EILSEQ;
        }
        return DARWIN_RECORD_REJECTED;
    }
    if (!(returned.commonattr & ATTR_CMN_MODTIME) || !(returned.commonattr & ATTR_CMN_FILEID) ||
        (item->object_type == DARWIN_VREG && !(returned.fileattr & ATTR_FILE_DATALENGTH))) {
        item->flags |= DARWIN_ITEM_STAT_FAILED;
        item->error = EIO;
    }
    return DARWIN_RECORD_OK;
}

/* ------------------------------------------------------------------ */
/* getattrlistbulk: one-shot directory drain                           */
/* ------------------------------------------------------------------ */

uint32_t darwin_bulk_item_size(void) { return (uint32_t)sizeof(darwin_bulk_item); }

static void build_attrlist(struct attrlist *list) {
    memset(list, 0, sizeof(*list));
    list->bitmapcount = ATTR_BIT_MAP_COUNT;
    list->commonattr = DARWIN_BULK_COMMON_ATTRS;
    list->volattr = 0;
    list->dirattr = DARWIN_BULK_DIR_ATTRS;
    list->fileattr = DARWIN_BULK_FILE_ATTRS;
    list->forkattr = 0;
}

static int32_t negative_errno(void) {
    int saved = errno;
    return -(saved > 0 ? saved : EIO);
}

/* True for any vnode type the kernel can report for a directory entry. */
static int is_known_vtype(uint32_t value) {
    switch (value) {
    case DARWIN_VREG:
    case DARWIN_VDIR:
    case DARWIN_VCHR:
    case DARWIN_VBLK:
    case DARWIN_VLNK:
    case DARWIN_VSOCK:
    case DARWIN_VFIFO:
    case DARWIN_VWHT:
        return 1;
    default:
        return 0;
    }
}

int32_t darwin_directory_read_all(const char *path, darwin_bulk_item **out_items,
                                  uint32_t *out_count) {
    if (path == NULL || out_items == NULL || out_count == NULL) {
        return -EINVAL;
    }
    *out_items = NULL;
    *out_count = 0;

    struct attrlist list;
    build_attrlist(&list);

    const size_t record_size = sizeof(darwin_bulk_item);
    size_t raw_capacity = DARWIN_BULK_FIRST_BYTES;
    uint32_t out_capacity = (uint32_t)(DARWIN_BULK_FIRST_BYTES / record_size);

    unsigned char *raw = (unsigned char *)malloc(raw_capacity);
    darwin_bulk_item *items = (darwin_bulk_item *)malloc((size_t)out_capacity * record_size);
    if (raw == NULL || items == NULL) {
        free(raw);
        free(items);
        return -ENOMEM;
    }

    int descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        free(raw);
        free(items);
        return negative_errno();
    }

    uint32_t total = 0;
    uint32_t rejected = 0;
    int32_t result = 0;
    uint64_t offset = 0;

    for (;;) {
        /* getattrlistbulk returns the number of entries, not a byte count. */
        int count = getattrlistbulk(descriptor, &list, raw, raw_capacity, DARWIN_BULK_OPTIONS);
        if (count < 0) {
            result = negative_errno();
            break;
        }
        if (count == 0) {
            break; /* the only reliable end-of-directory signal */
        }

        offset = 0;
        for (int index = 0; index < count; index++) {
            if (offset > raw_capacity || raw_capacity - offset < DARWIN_RECORD_HEADER_BYTES) {
                result = -EILSEQ;
                break;
            }
            uint32_t record_length = 0;
            memcpy(&record_length, raw + offset, 4);
            if (record_length < DARWIN_RECORD_HEADER_BYTES ||
                record_length > raw_capacity - offset) {
                result = -EILSEQ;
                break;
            }

            /* Capacity is guaranteed before any write, so a rejected record
             * still has somewhere to land. */
            if (total == out_capacity) {
                uint64_t grown_bytes = (uint64_t)out_capacity * record_size * 2u;
                if (grown_bytes > DARWIN_BULK_MAX_BYTES) {
                    result = -DARWIN_EOVERFLOW;
                    break;
                }
                uint32_t target = (uint32_t)(grown_bytes / record_size);
                darwin_bulk_item *grown =
                    (darwin_bulk_item *)realloc(items, (size_t)target * record_size);
                if (grown == NULL) {
                    result = -ENOMEM;
                    break;
                }
                items = grown;
                out_capacity = target;
            }

            darwin_bulk_item item;
            darwin_record_status status = parse_record(
                raw, (uint64_t)raw_capacity, offset, &item);
            if (status == DARWIN_RECORD_BROKEN) {
                result = -EILSEQ;
                break;
            }
            if (status == DARWIN_RECORD_REJECTED) {
                rejected++;
            }

            items[total++] = item;
            offset += record_length;
        }
        if (result != 0) {
            break;
        }
        if ((size_t)count * 512u >= raw_capacity) {
            /* The buffer is filling; grow so the next call can make progress.
             * This is a capacity decision, not an end-of-directory signal. */
            size_t grown_raw = raw_capacity * 2u;
            if (grown_raw > DARWIN_BULK_MAX_BYTES) {
                grown_raw = DARWIN_BULK_MAX_BYTES;
            }
            if (grown_raw > raw_capacity) {
                unsigned char *grown_buffer = (unsigned char *)realloc(raw, grown_raw);
                if (grown_buffer == NULL) {
                    result = -ENOMEM;
                    break;
                }
                raw = grown_buffer;
                raw_capacity = grown_raw;
            }
        }
    }

    close(descriptor);
    free(raw);

    if (result < 0) {
        free(items);
        return result;
    }
    if (rejected > 0u) {
        /* Children were dropped for want of a faithful name. The listing is
         * still real and still worth indexing, so it is handed back with the
         * rejected records flagged rather than discarded: falling back here
         * would re-read the same directory and hit the same names. */
    }
    for (uint32_t index = 0; index < total; index++) {
        if (!is_known_vtype(items[index].object_type)) {
            free(items);
            return -EILSEQ;
        }
    }

    *out_items = items;
    *out_count = total;
    return (int32_t)total;
}

void darwin_directory_free(darwin_bulk_item *items) { free(items); }

/* ------------------------------------------------------------------ */
/* readdir + fstatat cursor                                            */
/* ------------------------------------------------------------------ */

struct darwin_directory {
    DIR *handle;
    int descriptor;
    int64_t fs_id_hi;
    int64_t fs_id_lo;
};

uint32_t darwin_mode_to_vtype(mode_t mode) {
    if (S_ISREG(mode)) {
        return DARWIN_VREG;
    }
    if (S_ISDIR(mode)) {
        return DARWIN_VDIR;
    }
    if (S_ISLNK(mode)) {
        return DARWIN_VLNK;
    }
    if (S_ISFIFO(mode)) {
        return DARWIN_VFIFO;
    }
    if (S_ISCHR(mode)) {
        return DARWIN_VCHR;
    }
    if (S_ISBLK(mode)) {
        return DARWIN_VBLK;
    }
    if (S_ISSOCK(mode)) {
        return DARWIN_VSOCK;
    }
    return DARWIN_VREG;
}

darwin_directory *darwin_directory_open(const char *path) {
    if (path == NULL) {
        errno = EINVAL;
        return NULL;
    }
    int opened = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (opened < 0) { return NULL; }
    DIR *handle = fdopendir(opened);
    if (handle == NULL) { int code = errno; close(opened); errno = code; return NULL; }
    darwin_directory *directory = (darwin_directory *)calloc(1, sizeof(darwin_directory));
    if (directory == NULL) {
        closedir(handle);
        errno = ENOMEM;
        return NULL;
    }
    directory->handle = handle;
    directory->descriptor = dirfd(handle);

    struct statfs info;
    if (fstatfs(directory->descriptor, &info) == 0) {
        directory->fs_id_hi = (int64_t)info.f_fsid.val[0];
        directory->fs_id_lo = (int64_t)info.f_fsid.val[1];
    }
    return directory;
}

int32_t darwin_directory_identity(darwin_directory *dir, int64_t *fs_id_hi, int64_t *fs_id_lo) {
    if (dir == NULL) {
        return -EINVAL;
    }
    if (fs_id_hi != NULL) {
        *fs_id_hi = dir->fs_id_hi;
    }
    if (fs_id_lo != NULL) {
        *fs_id_lo = dir->fs_id_lo;
    }
    return 0;
}

int32_t darwin_device_id(const char *path) {
    if (path == NULL) {
        return 0;
    }
    struct stat info;
    if (stat(path, &info) != 0) {
        return 0;
    }
    return (int32_t)info.st_dev;
}

static void fill_from_stat(darwin_bulk_item *item, const char *name, uint32_t length,
                           const struct stat *info) {
    memset(item, 0, sizeof(*item));
    memcpy(item->name, name, length);
    item->name[length] = '\0';
    item->name_length = length;
    item->file_id = (uint64_t)info->st_ino;
    item->object_type = darwin_mode_to_vtype(info->st_mode);
    if (S_ISREG(info->st_mode)) {
        item->size = (int64_t)info->st_size;
    }
    item->modified_at = (int64_t)info->st_mtimespec.tv_sec;
}

int32_t darwin_directory_next(darwin_directory *dir, darwin_bulk_item *buffer, uint32_t capacity,
                              uint32_t *out_count, int32_t *out_errno) {
    if (out_count != NULL) {
        *out_count = 0;
    }
    if (out_errno != NULL) {
        *out_errno = 0;
    }
    if (dir == NULL || buffer == NULL || capacity == 0u) {
        return -EINVAL;
    }

    uint32_t produced = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir->handle);
        if (entry == NULL) {
            /* readdir() signalling end-of-directory and readdir() failing are
             * distinguished by errno. Either way the enumeration stops here; a
             * non-zero *out_errno tells the caller the tail is unknown. */
            int saved = errno;
            if (saved != 0 && out_errno != NULL) {
                *out_errno = saved;
            }
            if (out_count != NULL) {
                *out_count = produced;
            }
            return 1;
        }

        const char *name = entry->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }
        size_t length = strlen(name);
        if (length == 0u || length >= 1024u) {
            continue;
        }
        if (produced >= capacity) {
            if (out_count != NULL) {
                *out_count = produced;
            }
            return 0;
        }

        struct stat info;
        /* AT_SYMLINK_NOFOLLOW: describe the link, never resolve it. */
        if (fstatat(dir->descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0) {
            if (!darwin_is_valid_utf8((const unsigned char *)name, (uint32_t)length)) {
                item_reject(&buffer[produced],
                            DARWIN_ITEM_UTF8_REJECTED | DARWIN_ITEM_STAT_FAILED, EILSEQ);
            } else {
                fill_from_stat(&buffer[produced], name, (uint32_t)length, &info);
            }
        } else {
            item_reject(&buffer[produced], DARWIN_ITEM_STAT_FAILED,
                        (uint32_t)(errno > 0 ? errno : EIO));
            memcpy(buffer[produced].name, name, length);
            buffer[produced].name[length] = '\0';
            buffer[produced].name_length = (uint32_t)length;
        }
        produced++;
    }
}

void darwin_directory_close(darwin_directory *dir) {
    if (dir == NULL) {
        return;
    }
    if (dir->handle != NULL) {
        closedir(dir->handle);
    }
    free(dir);
}

/* ------------------------------------------------------------------ */
/* Mount identity + diagnostic probe                                   */
/* ------------------------------------------------------------------ */

int32_t darwin_statfs_identity(const char *path, int64_t *fs_id_hi, int64_t *fs_id_lo,
                               char *fstype_name, uint32_t fstype_capacity) {
    if (path == NULL) {
        return -EINVAL;
    }
    struct statfs info;
    if (statfs(path, &info) != 0) {
        return negative_errno();
    }
    if (fs_id_hi != NULL) {
        *fs_id_hi = (int64_t)info.f_fsid.val[0];
    }
    if (fs_id_lo != NULL) {
        *fs_id_lo = (int64_t)info.f_fsid.val[1];
    }
    if (fstype_name != NULL && fstype_capacity > 0u) {
        size_t limit = sizeof(info.f_fstypename);
        if (limit > (size_t)fstype_capacity) {
            limit = (size_t)fstype_capacity;
        }
        memcpy(fstype_name, info.f_fstypename, limit);
        fstype_name[limit - 1u] = '\0';
    }
    return 0;
}

/*
 * Decodes a real directory and checks every record against the facts the kernel
 * must be reporting: a real vnode type, a name that decoded as UTF-8, and a
 * regular file with a plausible size.
 *
 * This is reported to the caller rather than used to silently disable the bulk
 * path: a parser that cannot read a directory is a defect, and quietly falling
 * back would hide exactly the failure worth seeing.
 */
int32_t darwin_bulk_probe(void) {
    darwin_bulk_item *items = NULL;
    uint32_t count = 0;
    int32_t result = darwin_directory_read_all("/", &items, &count);
    if (result < 0 || items == NULL) {
        free(items);
        return 0;
    }

    int ok = 1;
    for (uint32_t index = 0; index < count && ok; index++) {
        const darwin_bulk_item *item = &items[index];
        if (item->name_length == 0u || item->name[0] == '\0') {
            ok = 0;
        } else if (!darwin_is_valid_utf8(
                       (const unsigned char *)item->name, item->name_length)) {
            ok = 0;
        } else if (!is_known_vtype(item->object_type)) {
            ok = 0;

        } else if (item->object_type == DARWIN_VDIR && item->size != 0) {
            /* A directory has no ATTR_FILE_DATALENGTH, so its size must be 0.
             * A non-zero value here means the record offsets are wrong. */
            ok = 0;
        } else if (item->object_type == DARWIN_VLNK && item->size != 0) {
            ok = 0;
        } else if (strlen(item->name) != (size_t)item->name_length) {
            ok = 0;
        }
    }

    darwin_directory_free(items);
    return ok ? 1 : 0;
}