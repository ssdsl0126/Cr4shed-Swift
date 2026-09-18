#import "Cr4shedCommon.h"
#include <dlfcn.h>

NSString *CR4StringFromDate(NSDate *date, CR4DateFormat type) {
    BOOL needsLowercase = NO;
    NSDateFormatter *formatter = [NSDateFormatter new];
    switch (type) {
        case CR4DateFormatPretty:
            [formatter setDateStyle:NSDateFormatterShortStyle];
            [formatter setTimeStyle:NSDateFormatterShortStyle];
            break;
        case CR4DateFormatTimeOnly:
            [formatter setDateStyle:NSDateFormatterNoStyle];
            [formatter setTimeStyle:NSDateFormatterShortStyle];
            break;
        default:
            needsLowercase = YES;
            [formatter setDateFormat:@"yyyy-MM-dd_h:mm_a"];
            break;
    }
    NSString *ret = [formatter stringFromDate:date];
    return needsLowercase ? [ret lowercaseString] : ret;
}

typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef, CFDictionaryRef);

static NSString *CR4MG(CFStringRef key) {
    static MGCopyAnswerFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (h) fn = (MGCopyAnswerFn)dlsym(h, "MGCopyAnswer");
    });
    if (!fn) return nil;
    CFTypeRef value = fn(key, NULL);
    if (!value) return nil;
    return (__bridge_transfer NSString *)value;
}

NSString *CR4DeviceVersion(void) {
    return CR4MG(CFSTR("ProductVersion")) ?: @"Unknown";
}

NSString *CR4DeviceName(void) {
    return CR4MG(CFSTR("marketing-name")) ?: @"Unknown";
}

NSString *CR4AddInfoToLog(NSString *logContents, NSDictionary *info) {
    if (![NSJSONSerialization isValidJSONObject:info]) return logContents;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:info options:0 error:NULL];
    if (!jsonData) return logContents;
    NSString *infoString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [logContents stringByAppendingFormat:@"\n\n%@", infoString];
}

NSDictionary *CR4GetInfoFromLog(NSString *logContents) {
    if (!logContents.length) return nil;
    NSRange lastLineRange = [logContents lineRangeForRange:NSMakeRange(logContents.length - 1, 1)];
    NSString *jsonString = [logContents substringWithRange:lastLineRange];
    id info = [NSJSONSerialization JSONObjectWithData:[jsonString dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    return [info isKindOfClass:[NSDictionary class]] ? info : nil;
}
