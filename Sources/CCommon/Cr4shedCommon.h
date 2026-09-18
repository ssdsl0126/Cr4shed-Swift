#ifndef CR4SHED_COMMON_H
#define CR4SHED_COMMON_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <mach/mach.h>
#import <Foundation/Foundation.h>

#define CR4SHED_DAEMON_MACH "com.muirey03.cr4shedd"
#define CR4SHED_PREFS_ID "com.muirey03.cr4shedprefs"
#define CR4SHED_GUI_BUNDLE "com.muirey03.cr4shedgui"
#define CR4SHED_HANDLED_FLAG "com.muirey03.cr4shed-exceptionHandled"

#define kSortingMethod @"SortingMethod"
#define kProcessBlacklist @"ProcessBlacklist"
#define kEnableJetsam @"EnableJetsam"

#define CR4ProcsNeedRefreshNotificationName @"com.muirey03.cr4shed-procsNeedRefresh"
#define CR4BlacklistDidChangeNotificationName @"com.muirey03.cr4shed-blacklistDidChange"

typedef NS_ENUM(NSInteger, CR4DateFormat) {
    CR4DateFormatPretty = 0,
    CR4DateFormatTimeOnly,
    CR4DateFormatFilename
};

typedef NS_ENUM(int64_t, CR4XPCMessageID) {
    CR4XPCWriteString = 1,
    CR4XPCIsBlacklisted = 2,
    CR4XPCShouldLogJetsam = 3,
    CR4XPCStringFromTime = 4
};

#ifdef __cplusplus
extern "C" {
#endif

NSString *CR4JBRootPath(NSString *path);
const char *CR4JBRootPathC(const char *path);
NSString *CR4LogDirectory(void);
NSString *CR4PrefsPath(void);

void CR4HookFunction(void *symbol, void *replace, void **original);
void CR4HookMessage(Class cls, SEL sel, IMP imp, IMP *orig);

NSDictionary *CR4XPCSend(CR4XPCMessageID messageID, NSDictionary *userInfo);
NSString *CR4WriteLog(NSString *contents, NSString *filename);
NSString *CR4LocalWriteLog(NSString *contents, NSString *filename);
void CR4SendNotification(NSString *content, NSString *logPath);
bool CR4IsProcessBlacklisted(NSString *procName);
bool CR4ShouldLogJetsam(void);
NSString *CR4StringFromTime(time_t t, CR4DateFormat type);
void *CR4XPCCreateMachService(const char *name, uint64_t flags);
void CR4RunXPCListener(void *_Nullable (^ _Nonnull handler)(void *_Nonnull message));

NSString *CR4StringFromDate(NSDate *date, CR4DateFormat type);
NSString *CR4DeviceVersion(void);
NSString *CR4DeviceName(void);
NSString *CR4AddInfoToLog(NSString *logContents, NSDictionary *info);
NSDictionary *CR4GetInfoFromLog(NSString *logContents);

NSString *CR4GetImageFromSymbol(NSString *symbol);
NSString *CR4DetermineCulprit(NSArray *symbols);
NSString *CR4DetermineCulpritWithAddresses(NSArray *symbols, NSArray *addresses);
NSArray<NSString *> *CR4GetAllKnownTweakNames(void);

void CR4MarkProcessAsHandled(void);
bool CR4ProcessHasBeenHandled(mach_port_t task);

size_t CR4RRead(mach_port_t task, mach_vm_address_t where, void *p, size_t size);
char *CR4RReadString(mach_port_t task, vm_address_t addr);
uint64_t CR4RRead64(mach_port_t task, mach_vm_address_t where);
uint32_t CR4RRead32(mach_port_t task, mach_vm_address_t where);
mach_vm_address_t CR4TaskGetImageInfos(mach_port_t task);

NSString *CR4NameForLocalSymbol(NSNumber *addrNum, uint64_t *outOffset);
NSArray *CR4SymbolicatedException(NSException *e);
NSString *CR4NameForRemoteSymbol(uint64_t addr, NSString *path, NSString *uuidStr, uint64_t imgAddr, int32_t archCpuType, int32_t archCpuSubtype);
mach_vm_address_t CR4FindSymbolInTask(mach_port_t task, const char *symbolName, NSString *lastPathComponent, NSString **imageName);

NSArray<NSString *> *CR4HardBlacklist(void);
bool CR4IsHardBlacklisted(NSString *procName);

NSArray *CR4PrefsBlacklist(void);
bool CR4PrefsEnableJetsam(void);
NSString *CR4PrefsSortingMethod(void);
void CR4PrefsSetObject(id value, NSString *key);

BOOL CR4BoolMessage(id object, SEL sel);
NSString *CR4ReadStringAtTaskAddress(id report, uint64_t addr);

typedef struct {
    uint64_t pc;
    uint64_t lr;
    uint32_t cpsr;
    uint64_t x[29];
} CR4ParsedThreadState;

bool CR4ParseThreadState(const void *bytes, size_t size, int32_t flavor, CR4ParsedThreadState *outState);
void CR4DisplaySystemNotice(NSString *title, NSString *message);

#ifdef __cplusplus
}
#endif

#endif
