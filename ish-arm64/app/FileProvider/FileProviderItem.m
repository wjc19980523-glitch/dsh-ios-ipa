//
//  FileProviderItem.m
//  iSHFiles
//
//  Created by Theodore Dubois on 9/20/18.
//

#import <MobileCoreServices/MobileCoreServices.h>
#include <sys/stat.h>
#include <dirent.h>
#import "FileProviderExtension.h"
#import "FileProviderItem.h"
#import "FileProviderDB.h"
#include "fs/fake-db.h"
#include "kernel/errno.h"

@interface FileProviderItem ()

@property (readonly) NSFileProviderItemIdentifier identifier;
@property (readonly) int fd;
@property (readonly) BOOL isRoot;

@end

@implementation FileProviderItem

- (instancetype)initWithIdentifier:(NSFileProviderItemIdentifier)identifier mount:(struct fakefs_mount *)mount error:(NSError *__autoreleasing  _Nullable *)error {
    if (self = [super init]) {
        _identifier = identifier;
        _mount = mount;
        _fd = [self openNewFDWithError:error];
        if (_fd == -1)
            return nil;
    }
    return self;
}

- (BOOL)isRoot {
    return [self.identifier isEqualToString:NSFileProviderRootContainerItemIdentifier];
}

- (int)openNewFDWithError:(NSError *__autoreleasing  _Nullable *)error {
    int fd = -1;
    if (self.isRoot) {
        fd = open(_mount->source, O_DIRECTORY | O_RDONLY);
    } else {
        int result = db_begin_read(&_mount->db);
        if (!FileProviderDBResult(result, error)) return -1;
        sqlite3_stmt *stmt = _mount->db.stmt.path_from_inode;
        result = sqlite3_bind_int64(stmt, 1, _identifier.longLongValue);
        int hostError = ENOENT;
        while (result == SQLITE_OK && (result = db_exec(&_mount->db, stmt)) == SQLITE_ROW) {
            const char *path = (const char *) sqlite3_column_text(stmt, 0);
            fd = openat(_mount->root_fd, fix_path(path), O_RDWR);
            if (fd == -1 && errno == EISDIR)
                fd = openat(_mount->root_fd, fix_path(path), O_RDONLY);
            if (fd >= 0) break;
            hostError = errno;
            if (hostError != ENOENT) break;
            result = SQLITE_OK;
        }
        int reset = db_reset(&_mount->db, stmt);
        if ((result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE) && reset != SQLITE_OK)
            result = reset;
        result = FileProviderDBFinishRead(&_mount->db, result);
        if (!FileProviderDBResult(result, error)) {
            if (fd >= 0) close(fd);
            return -1;
        }
        if (fd < 0) errno = hostError;
    }
    if (fd == -1) {
        if (error != nil) {
            if (errno == ENOENT)
                *error = [NSError fileProviderErrorForNonExistentItemWithIdentifier:_identifier];
            else
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        NSLog(@"opening %@ failed (%d)", self.identifier, errno);
        return -1;
    }
    return fd;
}

- (NSString *)path {
    char path[PATH_MAX] = "";
    int err = fcntl(_fd, F_GETPATH, path);
    [self handleError:err inFunction:@"getpath"];
    const char *myPath = path + strlen(_mount->source);
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:myPath length:strlen(myPath)];
}

- (NSURL *)URL {
    NSURL *rootURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:_mount->source]];
    if (self.isRoot)
        return rootURL;
    return [rootURL URLByAppendingPathComponent:self.path];
}

- (struct ish_stat)ishStat {
    struct ish_stat stat = {};
    int result = db_begin_read(&_mount->db);
    if (!FileProviderDBResult(result, nil)) return stat;
    inode_t inode = _identifier.longLongValue;
    if ([_identifier isEqualToString:NSFileProviderRootContainerItemIdentifier])
        inode = path_get_inode(&_mount->db, "");
    inode_read_stat_or_die(&_mount->db, inode, &stat);
    result = FileProviderDBFinishRead(&_mount->db, SQLITE_OK);
    if (!FileProviderDBResult(result, nil)) memset(&stat, 0, sizeof(stat));
    return stat;
}
- (struct stat)realStat {
    struct stat statbuf;
    int err = fstat(_fd, &statbuf);
    [self handleError:err inFunction:@"realStat"];
    return statbuf;
}

- (NSFileProviderItemIdentifier)itemIdentifier {
    if (self.isRoot)
        return NSFileProviderRootContainerItemIdentifier;
    return _identifier;
}
- (NSFileProviderItemIdentifier)parentItemIdentifier {
    if (self.isRoot) {
        NSLog(@"parent of root %@ is %@", self.path, NSFileProviderRootContainerItemIdentifier);
        return NSFileProviderRootContainerItemIdentifier;
    }
    NSString *parentPath = self.path.stringByDeletingLastPathComponent;
    if ([parentPath isEqualToString:@"/"])
        return NSFileProviderRootContainerItemIdentifier;
    int result = db_begin_read(&_mount->db);
    if (!FileProviderDBResult(result, nil)) return nil;
    inode_t parentInode = path_get_inode(&_mount->db, parentPath.UTF8String);
    result = FileProviderDBFinishRead(&_mount->db, SQLITE_OK);
    if (!FileProviderDBResult(result, nil) || parentInode == 0) return nil;
    NSString *parent = [NSString stringWithFormat:@"%lu", (unsigned long) parentInode];
    NSLog(@"parent of %@ is %@", self.path, parent);
    return parent;
}

- (NSFileProviderItemCapabilities)capabilities {
    NSFileProviderItemCapabilities caps = NSFileProviderItemCapabilitiesAllowsDeleting | NSFileProviderItemCapabilitiesAllowsRenaming | NSFileProviderItemCapabilitiesAllowsReparenting;
    if (S_ISREG(self.ishStat.mode))
        caps |= NSFileProviderItemCapabilitiesAllowsReading | NSFileProviderItemCapabilitiesAllowsWriting;
    else if (S_ISDIR(self.ishStat.mode))
        caps |= NSFileProviderItemCapabilitiesAllowsAddingSubItems | NSFileProviderItemCapabilitiesAllowsContentEnumerating;
    else
        return 0;
    return caps;
}

- (NSString *)filename {
    NSString *filename = self.path.lastPathComponent;
    if ([filename isEqualToString:@""])
        filename = @"/";
    NSLog(@"filename %@", filename);
    return filename;
}

- (NSNumber *)documentSize {
    struct stat statbuf;
    int err = fstat(_fd, &statbuf);
    [self handleError:err inFunction:@"documentSize"];
    return [NSNumber numberWithUnsignedLongLong:statbuf.st_size];
}

- (NSNumber *)childItemCount {
    if (!S_ISDIR(self.ishStat.mode))
        return @0;
    int fd = [self openNewFDWithError:nil];
    if (fd == -1)
        return @0;
    unsigned n = 0;
    DIR *dir = fdopendir(fd);
    struct dirent *dirent;
    while ((dirent = readdir(dir))) {
        if (strcmp(dirent->d_name, ".") == 0 || strcmp(dirent->d_name, "..") == 0)
            continue;
        n++;
    }
    closedir(dir);
    return @(n);
}

- (NSDate *)contentModificationDate {
    struct stat statbuf = self.realStat;
    return [NSDate dateWithTimeIntervalSince1970:statbuf.st_mtimespec.tv_sec + (NSTimeInterval) statbuf.st_mtimespec.tv_nsec / 1000000000];
}

- (NSString *)typeIdentifier {
    if (self.isRoot) {
        NSLog(@"uti of %@ is %@", self.path, (NSString *) kUTTypeFolder);
        return (NSString *) kUTTypeFolder;
    }
    mode_t_ mode = self.ishStat.mode;
    if ((mode & S_IFMT) == S_IFDIR)
        return (NSString *) kUTTypeFolder;
    if ((mode & S_IFMT) == S_IFLNK)
        return (NSString *) kUTTypeSymLink;
    NSString *uti = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension,
                                                                            (__bridge CFStringRef _Nonnull) self.path.pathExtension, nil));
    if ([uti hasPrefix:@"dyn."])
        uti = (NSString *) kUTTypePlainText;
    NSLog(@"uti of %@ is %@", self.path, uti);
    return uti;
}

// locking on these keeps the remove/copy operation atomic
// or at least tries to

- (BOOL)loadToURL:(NSURL *)url error:(NSError **)error {
    NSLog(@"copying %@ to %@", self.path, url);
    NSURL *itemURL = self.URL;
    int result = db_begin_read(&_mount->db);
    if (!FileProviderDBResult(result, error)) return NO;
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    BOOL success = [NSFileManager.defaultManager copyItemAtURL:itemURL
                                                         toURL:url
                                                         error:error];
    if (!success) {
        // A copy can fail after replacing or partially writing its destination.
        // Preserve the coordination transaction instead of pretending rollback
        // can reverse that host mutation.
        db_require_recovery(&_mount->db, SQLITE_IOERR);
        return NO;
    }
    return FileProviderDBResult(db_commit(&_mount->db), error);
}

- (BOOL)saveFromURL:(NSURL *)url error:(NSError **)error {
    NSLog(@"copying %@ from %@", self.path, url);
    NSURL *itemURL = self.URL;
    int result = db_begin_read(&_mount->db);
    if (!FileProviderDBResult(result, error)) return NO;
    [NSFileManager.defaultManager removeItemAtURL:itemURL error:nil];
    BOOL success = [NSFileManager.defaultManager copyItemAtURL:url
                                                         toURL:itemURL
                                                         error:error];
    if (!success) {
        db_require_recovery(&_mount->db, SQLITE_IOERR);
        return NO;
    }
    return FileProviderDBResult(db_commit(&_mount->db), error);
}

- (void)dealloc {
    if (self.fd != -1)
        close(self.fd);
}

- (void)handleError:(long)err inFunction:(NSString *)func {
    if (err < 0) {
        [NSException raise:NSGenericException format:@"%@ returned %ld %d", func, err, errno];
    }
}

@end
