#import "Cr4shedCommon.h"

static NSMutableDictionary *CR4LoadPrefs(void) {
    NSMutableDictionary *prefs = [[NSMutableDictionary alloc] initWithContentsOfFile:CR4PrefsPath()];
    return prefs ?: [NSMutableDictionary dictionary];
}

static void CR4SavePrefs(NSDictionary *prefs) {
    [prefs writeToFile:CR4PrefsPath() atomically:YES];
}

NSArray *CR4PrefsBlacklist(void) {
    id value = CR4LoadPrefs()[kProcessBlacklist];
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

bool CR4PrefsEnableJetsam(void) {
    id value = CR4LoadPrefs()[kEnableJetsam];
    if (value == nil) return true;
    return [value boolValue];
}

NSString *CR4PrefsSortingMethod(void) {
    id value = CR4LoadPrefs()[kSortingMethod];
    return [value isKindOfClass:[NSString class]] ? value : @"Date";
}

void CR4PrefsSetObject(id value, NSString *key) {
    if (!key) return;
    NSMutableDictionary *prefs = CR4LoadPrefs();
    if (value) prefs[key] = value;
    else [prefs removeObjectForKey:key];
    CR4SavePrefs(prefs);
}
