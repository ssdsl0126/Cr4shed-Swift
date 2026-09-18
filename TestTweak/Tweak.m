#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <objc/runtime.h>

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

@interface Cr4DirectCrashButton : UIButton
@property (nonatomic, assign) BOOL isBadAccess;
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
    if (self.isBadAccess) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            triggerBadAccessCrash();
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            triggerNSExceptionCrash();
        });
    }
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
    // 只响应按钮本身的点击，其余空白区域完全穿透给 SpringBoard 桌面
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
        CGFloat panelW = 140.0;
        CGFloat panelH = 92.0;
        CGRect frame = CGRectMake(screenBounds.size.width - panelW - 12.0, 80.0, panelW, panelH);
        
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
        
        // 使用足够高的层级确保不被状态栏或壁纸拦截
        g_testWindow.windowLevel = 9999.0;
        g_testWindow.backgroundColor = [UIColor clearColor];
        g_testWindow.rootViewController = [UIViewController new];
        g_testWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
        
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
        panel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        panel.layer.cornerRadius = 14.0;
        panel.layer.borderWidth = 1.0;
        panel.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:0.8].CGColor;
        panel.clipsToBounds = YES;
        g_testWindow.containerView = panel;
        
        // 按钮 1：EXC_BAD_ACCESS (野指针崩溃)
        Cr4DirectCrashButton *btn1 = [Cr4DirectCrashButton buttonWithType:UIButtonTypeCustom];
        btn1.frame = CGRectMake(8, 8, panelW - 16, 34);
        btn1.isBadAccess = YES;
        btn1.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.95];
        [btn1 setTitle:@"💥 BAD_ACCESS" forState:UIControlStateNormal];
        btn1.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        btn1.layer.cornerRadius = 8.0;
        [panel addSubview:btn1];
        
        // 按钮 2：NSException (异常崩溃)
        Cr4DirectCrashButton *btn2 = [Cr4DirectCrashButton buttonWithType:UIButtonTypeCustom];
        btn2.frame = CGRectMake(8, 50, panelW - 16, 34);
        btn2.isBadAccess = NO;
        btn2.backgroundColor = [UIColor colorWithRed:0.85 green:0.55 blue:0.1 alpha:0.95];
        [btn2 setTitle:@"⚠️ NSException" forState:UIControlStateNormal];
        btn2.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        btn2.layer.cornerRadius = 8.0;
        [panel addSubview:btn2];
        
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
    // 兜底延迟创建
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        setupFloatingButton();
    });
}
