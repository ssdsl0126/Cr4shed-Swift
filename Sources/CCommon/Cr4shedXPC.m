#include <sys/stat.h>
#import "Cr4shedCommon.h"
#include <xpc/xpc.h>
#include <string.h>
#include <dlfcn.h>
#include <errno.h>
#include <unistd.h>

static xpc_connection_t (*CR4XPCCreateMachServicePtr)(const char *, dispatch_queue_t, uint64_t);
typedef int (*CR4LibSandyApplyProfileFn)(const char *);
static CR4LibSandyApplyProfileFn CR4LibSandyApplyProfilePtr;
static void *CR4LibSandyHandle;

static void CR4XPCResolve(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CR4XPCCreateMachServicePtr = dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    });
}

static xpc_object_t CR4NSToXPC(NSDictionary *dict) {
    xpc_object_t xpcDict = xpc_dictionary_create(NULL, NULL, 0);
    [dict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) return;
        const char *cKey = [key UTF8String];
        if ([obj isKindOfClass:[NSString class]]) {
            xpc_dictionary_set_string(xpcDict, cKey, [obj UTF8String]);
        } else if ([obj isKindOfClass:[NSNumber class]]) {
            const char *t = [obj objCType];
            if (strcmp(t, @encode(BOOL)) == 0 || strcmp(t, @encode(bool)) == 0 || strcmp(t, @encode(char)) == 0) {
                xpc_dictionary_set_bool(xpcDict, cKey, [obj boolValue]);
            } else if (strcmp(t, @encode(float)) == 0 || strcmp(t, @encode(double)) == 0) {
                xpc_dictionary_set_double(xpcDict, cKey, [obj doubleValue]);
            } else {
                xpc_dictionary_set_int64(xpcDict, cKey, [obj longLongValue]);
            }
        } else if ([obj isKindOfClass:[NSDictionary class]]) {
            xpc_object_t nested = CR4NSToXPC(obj);
            xpc_dictionary_set_value(xpcDict, cKey, nested);
        }
    }];
    return xpcDict;
}

static NSDictionary *CR4XPCToNS(xpc_object_t xpcDict) {
    if (!xpcDict || xpc_get_type(xpcDict) != XPC_TYPE_DICTIONARY) return @{};
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    xpc_dictionary_apply(xpcDict, ^bool(const char *key, xpc_object_t value) {
        if (!key || !value) return true;
        NSString *nsKey = [NSString stringWithUTF8String:key];
        xpc_type_t type = xpc_get_type(value);
        if (type == XPC_TYPE_STRING) {
            dict[nsKey] = [NSString stringWithUTF8String:xpc_string_get_string_ptr(value)];
        } else if (type == XPC_TYPE_INT64) {
            dict[nsKey] = @(xpc_int64_get_value(value));
        } else if (type == XPC_TYPE_BOOL) {
            dict[nsKey] = @(xpc_bool_get_value(value));
        } else if (type == XPC_TYPE_DOUBLE) {
            dict[nsKey] = @(xpc_double_get_value(value));
        } else if (type == XPC_TYPE_DICTIONARY) {
            dict[nsKey] = CR4XPCToNS(value);
        }
        return true;
    });
    return [dict copy];
}

int CR4ApplySandboxProfile(NSString *profileName) {
    if (!profileName.length) return -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CR4LibSandyApplyProfilePtr = (CR4LibSandyApplyProfileFn)dlsym(RTLD_DEFAULT, "libSandy_applyProfile");
        if (CR4LibSandyApplyProfilePtr) return;

        const char *rootlessPath = CR4JBRootPathC("/usr/lib/libsandy.dylib");
        if (rootlessPath) CR4LibSandyHandle = dlopen(rootlessPath, RTLD_NOW | RTLD_LOCAL);
        if (!CR4LibSandyHandle) CR4LibSandyHandle = dlopen("/usr/lib/libsandy.dylib", RTLD_NOW | RTLD_LOCAL);
        if (CR4LibSandyHandle) {
            CR4LibSandyApplyProfilePtr = (CR4LibSandyApplyProfileFn)dlsym(CR4LibSandyHandle, "libSandy_applyProfile");
        }
    });
    if (!CR4LibSandyApplyProfilePtr) {
        CR4DebugLog(@"[Cr4shed] libSandy_applyProfile is unavailable");
        return -1;
    }
    return CR4LibSandyApplyProfilePtr(profileName.UTF8String);
}

NSDictionary *CR4XPCSend(CR4XPCMessageID messageID, NSDictionary *userInfo) {
    CR4XPCResolve();
    if (!CR4XPCCreateMachServicePtr) return @{};
    xpc_connection_t connection = CR4XPCCreateMachServicePtr(CR4SHED_DAEMON_MACH, NULL, (1ull << 1));
    if (!connection) return @{};
    xpc_connection_set_event_handler(connection, ^(xpc_object_t object) {
        (void)object;
    });
    xpc_connection_resume(connection);

    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(message, "id", messageID);
    xpc_dictionary_set_value(message, "userInfo", CR4NSToXPC(userInfo ?: @{}));
    // 回复使用独立队列；等待最多一秒，守护进程无应答时允许调用方回退。
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSObject *replyLock = [NSObject new];
    __block NSDictionary *result = @{};
    __block BOOL finished = NO;
    xpc_connection_send_message_with_reply(connection, message, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
        NSDictionary *received = @{};
        if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
            received = CR4XPCToNS(xpc_dictionary_get_value(reply, "userInfo"));
        } else if (reply && xpc_get_type(reply) == XPC_TYPE_ERROR) {
            const char *description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
            CR4DebugLog(@"[Cr4shed] XPC request %lld failed: %s", (long long)messageID, description ?: "unknown error");
        }
        @synchronized (replyLock) {
            if (!finished) {
                result = received;
                finished = YES;
            }
        }
        dispatch_semaphore_signal(semaphore);
    });
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    NSDictionary *snapshot;
    @synchronized (replyLock) {
        if (!finished) CR4DebugLog(@"[Cr4shed] XPC request %lld timed out", (long long)messageID);
        finished = YES;
        snapshot = result;
    }
    xpc_connection_cancel(connection);
    return snapshot;
}

static NSString *CR4DaemonWriteLog(NSString *contents, NSString *filename, NSString *eventID, NSString *notificationContent) {
    NSMutableDictionary *userInfo = [@{
        @"string": contents,
        @"filename": filename,
        @"eventID": eventID
    } mutableCopy];
    if (notificationContent.length) userInfo[@"notificationContent"] = notificationContent;
    NSDictionary *reply = CR4XPCSend(CR4XPCWriteString, userInfo);
    NSString *path = reply[@"path"];
    return [path isKindOfClass:[NSString class]] && path.length ? path : nil;
}

static void CR4NotifyForWrittenLog(NSString *filename, NSString *path, NSString *notificationContent) {
    NSString *process = [[filename componentsSeparatedByString:@"@"] firstObject] ?: filename;
    NSString *pretty = CR4StringFromDate([NSDate date], CR4DateFormatPretty) ?: @"";
    NSString *msg = notificationContent.length
        ? notificationContent
        : [NSString stringWithFormat:@"%@ crashed at %@", process, pretty];
    CR4SendNotification(msg, path);
}

NSString *CR4WriteLog(NSString *contents, NSString *filename) {
    if (!contents || !filename.length) return nil;
    NSString *eventID = NSUUID.UUID.UUIDString;
    // 先完成本地保存，再异步通知；进程退出不会取消已完成的写入。
    NSString *localPath = CR4LocalWriteLogForEvent(contents, filename, eventID);
    if (localPath.length) {
        CR4NotifyForWrittenLog(filename, localPath, nil);
        return localPath;
    }
    // 本地写入失败时回退给守护进程 XPC
    return CR4DaemonWriteLog(contents, filename, eventID, nil);
}

NSString *CR4WriteLogViaDaemon(NSString *contents, NSString *filename, NSString *notificationContent) {
    if (!contents || !filename.length) return nil;
    NSString *eventID = NSUUID.UUID.UUIDString;
    NSString *daemonPath = CR4DaemonWriteLog(contents, filename, eventID, notificationContent);
    if (daemonPath.length) return daemonPath;

    // 报告进程无法联系守护进程时仍尝试使用已申请的文件扩展直接保存。
    // 超时并不代表对端未保存；两条路径必须使用同一个事件标识。
    NSString *localPath = CR4LocalWriteLogForEvent(contents, filename, eventID);
    if (localPath.length) CR4NotifyForWrittenLog(filename, localPath, notificationContent);
    return localPath;
}

bool CR4IsProcessBlacklisted(NSString *procName) {
    if (!procName.length) procName = [NSProcessInfo processInfo].processName;
    if (CR4IsHardBlacklisted(procName)) return true;
    NSArray *blacklist = CR4PrefsBlacklist();
    if ([blacklist isKindOfClass:[NSArray class]] && [blacklist containsObject:procName]) {
        return true;
    }
    return false;
}

bool CR4ShouldLogJetsam(void) {
    return CR4PrefsEnableJetsam();
}

NSString *CR4StringFromTime(time_t t, CR4DateFormat type) {
    if (!t) t = time(NULL);
    return CR4StringFromDate([NSDate dateWithTimeIntervalSince1970:t], type);
}

void *CR4XPCCreateMachService(const char *name, uint64_t flags) {
    CR4XPCResolve();
    if (!CR4XPCCreateMachServicePtr || !name) return NULL;
    return (__bridge void *)CR4XPCCreateMachServicePtr(name, NULL, flags);
}

void CR4RunXPCListener(NSDictionary<NSString *, id> * (^handler)(int64_t messageID, NSDictionary<NSString *, id> *userInfo)) {
    CR4XPCResolve();
    if (!CR4XPCCreateMachServicePtr) return;
    xpc_connection_t listener = CR4XPCCreateMachServicePtr(CR4SHED_DAEMON_MACH, NULL, (1ull << 0));
    if (!listener) return;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;

            int64_t messageID = xpc_dictionary_get_int64(message, "id");
            NSDictionary *userInfo = CR4XPCToNS(xpc_dictionary_get_value(message, "userInfo"));
            NSDictionary *result = handler ? handler(messageID, userInfo) : @{};
            if (![result isKindOfClass:[NSDictionary class]]) result = @{};

            xpc_object_t reply = xpc_dictionary_create_reply(message);
            if (!reply) reply = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_value(reply, "userInfo", CR4NSToXPC(result));
            xpc_connection_send_message(peer, reply);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
}
NSString *CR4LocalWriteLog(NSString *contents, NSString *rawName) {
    return CR4LocalWriteLogForEvent(contents, rawName, NSUUID.UUID.UUIDString);
}

NSString *CR4LocalWriteLogForEvent(NSString *contents, NSString *rawName, NSString *eventID) {
    if (!contents.length || !rawName.length) return nil;
    NSUUID *eventUUID = [[NSUUID alloc] initWithUUIDString:eventID];
    if (!eventUUID) return nil;
    NSString *filename = [rawName lastPathComponent];
    NSString *stem = [filename.pathExtension isEqualToString:@"log"] ? [filename stringByDeletingPathExtension] : filename;
    NSString *full = [NSString stringWithFormat:@"%@ (%@).log", stem, eventUUID.UUIDString];
    if ([full pathComponents].count > 1) return nil;
    NSString *dir = CR4LogDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:dir isDirectory:&isDir];
    if (!exists || !isDir) {
        if (exists) return nil;
        NSDictionary *dirAttrs = @{
            NSFilePosixPermissions: @0755,
            NSFileOwnerAccountName: @"mobile",
            NSFileGroupOwnerAccountName: @"mobile"
        };
        NSError *error;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:dirAttrs error:&error]) {
            // 另一保存路径可能已经创建成功，重新检查后再判定失败。
            if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
                CR4DebugLog(@"[Cr4shed] Cannot create log directory: %@", error);
                return nil;
            }
        }
    }
    NSString *path = [dir stringByAppendingPathComponent:full];
    NSDictionary *attrs = @{
        NSFilePosixPermissions: @0666,
        NSFileOwnerAccountName: @"mobile",
        NSFileGroupOwnerAccountName: @"mobile"
    };
    NSData *data = [contents dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    if ([fm fileExistsAtPath:path]) {
        if ([[NSData dataWithContentsOfFile:path] isEqualToData:data]) return path;
        CR4DebugLog(@"[Cr4shed] Existing report does not match event %@", eventID);
        return nil;
    }
    // 临时文件不以 .log 结尾，监听器只会看见完整发布的报告。
    NSString *temporary = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".cr4-%@.tmp", NSUUID.UUID.UUIDString]];
    NSError *error;
    if (![data writeToFile:temporary options:NSDataWritingWithoutOverwriting error:&error]) {
        if (![error.domain isEqualToString:NSCocoaErrorDomain] || error.code != NSFileWriteFileExistsError) {
            [fm removeItemAtPath:temporary error:NULL];
        }
        CR4DebugLog(@"[Cr4shed] Cannot write log %@: %@", eventID, error);
        return nil;
    }
    // 非 root 写入者可能无法调整属主，但仍必须让 App 和另一保存路径可读。
    [fm setAttributes:attrs ofItemAtPath:temporary error:NULL];
    if (chmod(temporary.fileSystemRepresentation, 0666) != 0) {
        int savedError = errno;
        [fm removeItemAtPath:temporary error:NULL];
        CR4DebugLog(@"[Cr4shed] Cannot set log permissions: %s", strerror(savedError));
        return nil;
    }
    // link 原子发布且不覆盖已有文件；迟到的 XPC 写入会复用同一完整报告。
    int status = link(temporary.fileSystemRepresentation, path.fileSystemRepresentation);
    int savedError = errno;
    [fm removeItemAtPath:temporary error:NULL];
    if (status == 0) return path;
    if (savedError == EEXIST && [[NSData dataWithContentsOfFile:path] isEqualToData:data]) return path;
    CR4DebugLog(@"[Cr4shed] Cannot publish log %@: %s", eventID, strerror(savedError));
    return nil;
}

void CR4SendNotification(NSString *content, NSString *logPath) {
    if (!content.length) return;
    CR4XPCResolve();
    if (!CR4XPCCreateMachServicePtr) return;
    xpc_connection_t connection = CR4XPCCreateMachServicePtr(CR4SHED_DAEMON_MACH, NULL, (1ull << 1));
    if (!connection) return;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t object) {});
    xpc_connection_resume(connection);

    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(message, "id", CR4XPCWriteString);
    xpc_object_t userDict = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(userDict, "string", "");
    xpc_dictionary_set_string(userDict, "filename", "");
    xpc_dictionary_set_bool(userDict, "notifyOnly", true);
    xpc_dictionary_set_string(userDict, "content", content.UTF8String ?: "");
    if (logPath.length) xpc_dictionary_set_string(userDict, "logPath", logPath.UTF8String);
    xpc_dictionary_set_value(message, "userInfo", userDict);

    // 异步发送；回复或超时后释放连接，不占用报告线程等待通知。
    xpc_connection_send_message_with_reply(connection, message, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t reply) {
        xpc_connection_cancel(connection);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        xpc_connection_cancel(connection);
    });
}

void CR4ReportMachReady(NSString *targetClass, int64_t hookCount) {
    if (!targetClass.length || hookCount <= 0) return;
    CR4XPCResolve();
    if (!CR4XPCCreateMachServicePtr) return;
    xpc_connection_t connection = CR4XPCCreateMachServicePtr(CR4SHED_DAEMON_MACH, NULL, (1ull << 1));
    if (!connection) return;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t object) {});
    xpc_connection_resume(connection);

    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(message, "id", CR4XPCMachReady);
    xpc_object_t userDict = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(userDict, "pid", getpid());
    xpc_dictionary_set_string(userDict, "targetClass", targetClass.UTF8String ?: "");
    xpc_dictionary_set_int64(userDict, "hookCount", hookCount);
    xpc_dictionary_set_value(message, "userInfo", userDict);

    // 构造阶段不能同步等待 daemon；回复仅用于确认消息生命周期结束。
    xpc_connection_send_message_with_reply(connection, message, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t reply) {
        xpc_connection_cancel(connection);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        xpc_connection_cancel(connection);
    });
}
