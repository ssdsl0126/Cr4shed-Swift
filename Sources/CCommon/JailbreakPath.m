#import "Cr4shedCommon.h"
#include "libroot.h"
#include <string.h>

NSString *CR4JBRootPath(NSString *path) {
    if (!path) return nil;
    const char *converted = libroot_dyn_jbrootpath(path.fileSystemRepresentation, NULL);
    if (!converted) return path;
    NSString *result = [NSString stringWithUTF8String:converted];
    if (converted != path.fileSystemRepresentation) free((void *)converted);
    return result ?: path;
}

const char *CR4JBRootPathC(const char *path) {
    if (!path) return path;
    static char buf[PATH_MAX];
    const char *converted = libroot_dyn_jbrootpath(path, buf);
    return converted ? converted : path;
}

NSString *CR4LogDirectory(void) {
    return CR4JBRootPath(@"/var/mobile/Library/Cr4shed");
}

NSString *CR4PrefsPath(void) {
    return CR4JBRootPath(@"/var/mobile/Library/Preferences/com.muirey03.cr4shedprefs.plist");
}
