#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <stdlib.h>

__attribute__((noinline))
void triggerBadAccessCrash(void) {
    NSLog(@"[Cr4Test] Triggering EXC_BAD_ACCESS in Cr4CrashTest.dylib...");
    volatile int *badAddress = (volatile int *)0xdeadbeef0000;
    *badAddress = 0x1337;
}

__attribute__((noinline))
void triggerNSExceptionCrash(void) {
    NSLog(@"[Cr4Test] Raising NSException in Cr4CrashTest.dylib...");
    [NSException raise:@"Cr4TestDeliberateCrash"
                format:@"Deliberate NSException from Cr4CrashTest.dylib to verify Cr4shed crash reporter"];
}

__attribute__((noinline))
void triggerAbortCrash(void) {
    NSLog(@"[Cr4Test] Triggering SIGABRT/abort in Cr4CrashTest.dylib...");
    abort();
}

__attribute__((noinline))
void triggerTrapCrash(void) {
    NSLog(@"[Cr4Test] Triggering SIGTRAP/__builtin_trap in Cr4CrashTest.dylib...");
    __builtin_trap();
}

typedef NS_ENUM(NSInteger, Cr4CrashType) {
    Cr4CrashTypeBadAccess = 0,
    Cr4CrashTypeNSException,
    Cr4CrashTypeAbort,
    Cr4CrashTypeTrap
};

@interface Cr4DirectCrashButton : UIButton
@property (nonatomic, assign) Cr4CrashType crashType;
@end

@implementation Cr4DirectCrashButton
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.alpha = 0.5;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.alpha = 1.0;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.alpha = 0.3;
    Cr4CrashType type = self.crashType;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        switch (type) {
            case Cr4CrashTypeBadAccess:
                triggerBadAccessCrash();
                break;
            case Cr4CrashTypeNSException:
                triggerNSExceptionCrash();
                break;
            case Cr4CrashTypeAbort:
                triggerAbortCrash();
                break;
            case Cr4CrashTypeTrap:
                triggerTrapCrash();
                break;
        }
    });
}
@end

@interface Cr4TestButtonWindow : UIWindow
@property (nonatomic, strong) UIView *containerView;
@end

@implementation Cr4TestButtonWindow

- (BOOL)_canAffectStatusBarAppearance { return NO; }
- (BOOL)_shouldCreateScreen { return NO; }
- (BOOL)canBecomeKeyWindow { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if ([hit isKindOfClass:[Cr4DirectCrashButton class]]) {
        return hit;
    }
    return nil;
}
@end

static Cr4TestButtonWindow *g_testWindow = nil;

static void setupFloatingButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_testWindow) return;
        
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat panelW = 148.0;
        CGFloat panelH = 176.0;
        CGRect frame = CGRectMake(screenBounds.size.width - panelW - 12.0, 70.0, panelW, panelH);
        
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    g_testWindow = [[Cr4TestButtonWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
                    break;
                }
            }
        }
        if (!g_testWindow) {
            g_testWindow = [[Cr4TestButtonWindow alloc] initWithFrame:frame];
        } else {
            g_testWindow.frame = frame;
        }
        
        g_testWindow.windowLevel = 9999.0;
        g_testWindow.backgroundColor = [UIColor clearColor];
        g_testWindow.rootViewController = [UIViewController new];
        g_testWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
        
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
        panel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.88];
        panel.layer.cornerRadius = 14.0;
        panel.layer.borderWidth = 1.0;
        panel.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:0.8].CGColor;
        panel.clipsToBounds = YES;
        g_testWindow.containerView = panel;
        
        // 按钮 1：EXC_BAD_ACCESS
        Cr4DirectCrashButton *btn1 = [Cr4DirectCrashButton buttonWithType:UIButtonTypeCustom];
        btn1.frame = CGRectMake(8, 8, panelW - 16, 34);
        btn1.crashType = Cr4CrashTypeBadAccess;
        btn1.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.95];
        [btn1 setTitle:@"💥 BAD_ACCESS" forState:UIControlStateNormal];
        btn1.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        btn1.layer.cornerRadius = 8.0;
        [panel addSubview:btn1];
        
        // 按钮 2：NSException
        Cr4DirectCrashButton *btn2 = [Cr4DirectCrashButton buttonWithType:UIButtonTypeCustom];
        btn2.frame = CGRectMake(8, 48, panelW - 16, 34);
        btn2.crashType = Cr4CrashTypeNSException;
        btn2.backgroundColor = [UIColor colorWithRed:0.85 green:0.55 blue:0.1 alpha:0.95];
        [btn2 setTitle:@"⚠️ NSException" forState:UIControlStateNormal];
        btn2.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        btn2.layer.cornerRadius = 8.0;
        [panel addSubview:btn2];

        // 按钮 3：SIGABRT (abort)
        Cr4DirectCrashButton *btn3 = [Cr4DirectCrashButton buttonWithType:UIButtonTypeCustom];
        btn3.frame = CGRectMake(8, 88, panelW - 16, 34);
        btn3.crashType = Cr4CrashTypeAbort;
        btn3.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.5 alpha:0.95];
        [btn3 setTitle:@"🛑 SIGABRT" forState:UIControlStateNormal];
        btn3.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        btn3.layer.cornerRadius = 8.0;
        [panel addSubview:btn3];

        // 按钮 4：SIGTRAP (trap/fatalError)
        Cr4DirectCrashButton *btn4 = [Cr4DirectCrashButton buttonWithType:UIButtonTypeCustom];
        btn4.frame = CGRectMake(8, 128, panelW - 16, 34);
        btn4.crashType = Cr4CrashTypeTrap;
        btn4.backgroundColor = [UIColor colorWithRed:0.2 green:0.45 blue:0.85 alpha:0.95];
        [btn4 setTitle:@"⚡️ SIGTRAP" forState:UIControlStateNormal];
        btn4.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        btn4.layer.cornerRadius = 8.0;
        [panel addSubview:btn4];
        
        [g_testWindow.rootViewController.view addSubview:panel];
        g_testWindow.hidden = NO;
    });
}

__attribute__((constructor))
static void Cr4TestInit(void) {
    NSLog(@"[Cr4Test] Cr4CrashTest loaded into %@", [NSProcessInfo processInfo].processName);
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        setupFloatingButton();
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        setupFloatingButton();
    });
}

