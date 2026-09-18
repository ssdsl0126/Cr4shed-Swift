#import "Cr4shedCommon.h"
#include <xpc/xpc.h>
#include <string.h>
#include <dlfcn.h>

static xpc_connection_t (*CR4XPCCreateMachServicePtr)(const char *, dispatch_queue_t, uint64_t);

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
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, message);
    NSDictionary *result = @{};
    if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
        xpc_object_t userInfoReply = xpc_dictionary_get_value(reply, "userInfo");
        result = CR4XPCToNS(userInfoReply);
    }
    return result;
}

NSString *CR4WriteLog(NSString *contents, NSString *filename) {
    if (!contents || !filename.length) return nil;
    // 优先本地直写磁盘，确保崩溃进程在被内核杀死前日志 100% 安全落盘
    NSString *localPath = CR4LocalWriteLog(contents, filename);
    if (localPath.length) {
        NSString *process = [[filename componentsSeparatedByString:@"@"] firstObject] ?: filename;
        NSString *pretty = CR4StringFromDate([NSDate date], CR4DateFormatPretty) ?: @"";
        NSString *msg = [NSString stringWithFormat:@"%@ crashed at %@", process, pretty];
        CR4SendNotification(msg, localPath);
        return localPath;
    }
    // 本地写入失败时回退给守护进程 XPC
    NSDictionary *reply = CR4XPCSend(CR4XPCWriteString, @{
        @"string": contents,
        @"filename": filename
    });
    NSString *path = reply[@"path"];
    return [path isKindOfClass:[NSString class]] ? path : nil;
}

bool CR4IsProcessBlacklisted(NSString *procName) {
    if (!procName.length) procName = [NSProcessInfo processInfo].processName;
    NSArray *blacklist = CR4PrefsBlacklist();
    if ([blacklist isKindOfClass:[NSArray class]] && [blacklist containsObject:procName]) {
        return true;
    }
    NSDictionary *reply = CR4XPCSend(CR4XPCIsBlacklisted, @{@"value": procName});
    return [reply[@"ret"] boolValue];
}

bool CR4ShouldLogJetsam(void) {
    return CR4PrefsEnableJetsam();
}

NSString *CR4StringFromTime(time_t t, CR4DateFormat type) {
    if (!t) t = time(NULL);
    NSDictionary *reply = CR4XPCSend(CR4XPCStringFromTime, @{@"time": @(t), @"type": @(type)});
    NSString *str = reply[@"ret"];
    if (str.length) return str;
    return CR4StringFromDate([NSDate dateWithTimeIntervalSince1970:t], type);
}

void *CR4XPCCreateMachService(const char *name, uint64_t flags) {
    CR4XPCResolve();
    if (!CR4XPCCreateMachServicePtr || !name) return NULL;
    return (__bridge void *)CR4XPCCreateMachServicePtr(name, NULL, flags);
}

void CR4RunXPCListener(void * (^handler)(void *message)) {
    CR4XPCResolve();
    if (!CR4XPCCreateMachServicePtr) return;
    xpc_connection_t listener = CR4XPCCreateMachServicePtr(CR4SHED_DAEMON_MACH, NULL, (1ull << 0));
    if (!listener) return;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
            void *reply = handler((__bridge void *)message);
            if (reply) {
                xpc_connection_send_message(peer, (__bridge_transfer xpc_object_t)reply);
            }
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
}
NSString *CR4LocalWriteLog(NSString *contents, NSString *rawName) {
    if (!contents.length || !rawName.length) return nil;
    NSString *filename = [rawName lastPathComponent];
    NSString *full = [filename stringByAppendingPathExtension:@"log"];
    if ([full pathComponents].count > 1) return nil;
    NSString *dir = CR4LogDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:dir isDirectory:&isDir];
    if (!exists || !isDir) {
        if (exists) [fm removeItemAtPath:dir error:NULL];
        NSDictionary *dirAttrs = @{
            NSFilePosixPermissions: @0755,
            NSFileOwnerAccountName: @"mobile",
            NSFileGroupOwnerAccountName: @"mobile"
        };
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:dirAttrs error:NULL];
    }
    NSString *path = [dir stringByAppendingPathComponent:full];
    for (unsigned long long i = 1; [fm fileExistsAtPath:path]; i++) {
        NSString *stem = [filename stringByDeletingPathExtension];
        path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%llu).log", stem, i]];
    }
    NSDictionary *attrs = @{
        NSFilePosixPermissions: @0666,
        NSFileOwnerAccountName: @"mobile",
        NSFileGroupOwnerAccountName: @"mobile"
    };
    NSData *data = [contents dataUsingEncoding:NSUTF8StringEncoding];
    if ([fm createFileAtPath:path contents:data attributes:attrs]) {
        return path;
    }
    return nil;
}

void CR4SendNotification(NSString *content, NSString *logPath) {
    if (!content.length) return;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"content"] = content;
    if (logPath.length) info[@"logPath"] = logPath;
    CR4XPCSend(CR4XPCWriteString, @{
        @"string": @"",
        @"filename": @"",
        @"notifyOnly": @YES,
        @"content": content,
        @"logPath": logPath ?: @""
    });
}
