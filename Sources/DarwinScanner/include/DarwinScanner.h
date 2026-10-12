/*
 * DarwinScanner — thin C bridge over the macOS bulk directory enumeration APIs.
 *
 * Two readers are exposed and both fill the exact same POD record, so the Swift
 * layer has a single decoding path:
 *
 *   darwin_directory_read_all()  getattrlistbulk(2), batched metadata
 *   darwin_directory_open/next() readdir(3) + fstatat(AT_SYMLINK_NOFOLLOW)
 *
 * Neither follows symbolic links: getattrlistbulk describes the link's own
 * inode and vnode type, and the fallback passes AT_SYMLINK_NOFOLLOW to fstatat.
 *
 * Bulk reading is fd based. The directory is opened once with
 * open(O_RDONLY|O_DIRECTORY) and getattrlistbulk(2) is called repeatedly on that
 * fd until it returns 0. getattrlistbulk returns the *number of entries*, not
 * a byte count, so a short return is not a signal that the directory is
 * finished — only 0 is.
 */

#ifndef DARWIN_SCANNER_H
#define DARWIN_SCANNER_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * ATTR_CMN_OBJTYPE reports the vnode type (XNU vnode.h), not the DT_* values
 * used by readdir(3). Mixing the two up makes every directory look like
 * something that is not a directory, and the walk then never descends.
 */
#define DARWIN_VREG 1u
#define DARWIN_VDIR 2u
#define DARWIN_VCHR 3u
#define DARWIN_VBLK 4u
#define DARWIN_VLNK 5u
#define DARWIN_VSOCK 6u
#define DARWIN_VFIFO 7u
#define DARWIN_VWHT 8u

/* Returned by the readers when a directory exceeds the in-C byte cap. */
#define DARWIN_EOVERFLOW 75

/* Bits set in darwin_bulk_item::flags. */
#define DARWIN_ITEM_IS_MOUNT_POINT 0x1u
/* This child could not be described; the listing is not complete. */
#define DARWIN_ITEM_STAT_FAILED 0x2u
/* The child's name was not valid UTF-8 and was therefore dropped. */
#define DARWIN_ITEM_UTF8_REJECTED 0x4u

typedef struct darwin_bulk_item {
    /* ATTR_CMN_FILEID (bulk) or st_ino (readdir cursor). */
    uint64_t file_id;
    /* ATTR_FILE_DATALENGTH for regular files, st_size otherwise. 0 for
     * directories and symbolic links. */
    int64_t size;
    /* ATTR_CMN_MODTIME / st_mtimespec, whole seconds since the Unix epoch. */
    int64_t modified_at;
    /* One of DARWIN_V*. */
    uint32_t object_type;
    uint32_t flags;
    /* errno for this child, 0 when it was described cleanly. */
    uint32_t error;
    /* strlen(name); 0 when the name was rejected. */
    uint32_t name_length;
    /* The common attribute set the kernel reported as returned. */
    uint32_t returned_attrs;
    /* Valid UTF-8, NUL terminated. Empty when the name was rejected. */
    char name[1024];
} darwin_bulk_item;

/*
 * Strict UTF-8 validation: no overlong forms, no surrogate halves, no code
 * points above U+10FFFF, no truncated sequences, no stray continuation bytes.
 *
 * Exposed because both readers must apply it. Validating only the bulk reader
 * would be useless: the fallback would happily emit a replacement-character
 * name for exactly the files the bulk reader refused, and those are the names
 * that silently point at something that does not exist.
 */
int darwin_is_valid_utf8(const unsigned char *bytes, uint32_t length);

/* Opaque readdir(3) cursor. */
typedef struct darwin_directory darwin_directory;

uint32_t darwin_bulk_item_size(void);

/* vnode type from st_mode, using the same DARWIN_V* codes as the bulk reader. */
uint32_t darwin_mode_to_vtype(mode_t mode);

/*
 * One-shot getattrlistbulk read of an entire directory.
 *
 * On success stores a malloc'd array in *out_items (release it with
 * darwin_directory_free) and its length in *out_count, returning that count.
 *
 * Returns a negative errno on failure:
 *   -DARWIN_EOVERFLOW  the directory is larger than the in-C cap; call again
 *                      through the cursor instead
 *   -EILSEQ           a record did not decode coherently; the caller must fall
 *                      back rather than index what was read
 */
int32_t darwin_directory_read_all(const char *path, darwin_bulk_item **out_items,
                                  uint32_t *out_count);

void darwin_directory_free(darwin_bulk_item *items);

/* Streaming readdir + fstatat cursor. NULL on failure with errno set. */
darwin_directory *darwin_directory_open(const char *path);

/*
 * Fills up to `capacity` records and stores how many were written in
 * *out_count. Returns 0 when the directory may have more entries, 1 when it is
 * exhausted, or a negative errno. A readdir() failure after some entries were
 * produced still returns 1 with the errno reported through *out_errno so the
 * caller can mark the directory partially enumerated rather than complete.
 */
int32_t darwin_directory_next(darwin_directory *dir, darwin_bulk_item *buffer, uint32_t capacity,
                              uint32_t *out_count, int32_t *out_errno);

/* statfs(2) identity of the directory this cursor was opened on. */
int32_t darwin_directory_identity(darwin_directory *dir, int64_t *fs_id_hi, int64_t *fs_id_lo);

/* dev_t of the filesystem a path lives on, 0 when it cannot be resolved. */
int32_t darwin_device_id(const char *path);

void darwin_directory_close(darwin_directory *dir);

/*
 * Decodes one real directory through the bulk reader and checks every record.
 * Returns 1 when the bulk path decodes coherently on this machine, 0 otherwise.
 *
 * This is a diagnostic, not a silent kill switch: the caller is expected to
 * report a failure here rather than quietly degrade to the fallback, because a
 * parser that cannot read a directory is a bug, not a missing feature.
 */
int32_t darwin_bulk_probe(void);

/*
 * statfs(2) identity of a path, used to decide "same mount".
 * fstype_name receives f_fstypename (the raw filesystem type, never inferred).
 */
int32_t darwin_statfs_identity(const char *path, int64_t *fs_id_hi, int64_t *fs_id_lo,
                               char *fstype_name, uint32_t fstype_capacity);

#ifdef __cplusplus
}
#endif

#endif /* DARWIN_SCANNER_H */