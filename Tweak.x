#import <UIKit/UIKit.h>
#import <dlfcn.h>

static NSArray *enabledApps = nil;
static BOOL revealServerLoadAttempted = NO;
static BOOL revealServerStarted = NO;

static NSArray<NSString *> *revealServerCandidates(void) {
    return @[
        @"/var/jb/Library/Application Support/RevealLoader/RevealServer.framework/RevealServer", // 适用于Reveal(24)
        @"/var/jb/Library/Application Support/RevealLoader/RevealServer" // 适用于Reveal(50)
    ];
}

static void loadPreferences() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.erik.revealloader.plist"];
    enabledApps = prefs[@"selectedApplications"] ?: @[];
    NSLog(@"[RevealLoader] Preferences loaded: %@ %@", enabledApps,prefs);
}

static void requestRevealStart(void) {
    if (revealServerStarted) {
        return;
    }

    Class loaderClass = %c(IBARevealLoader);
    NSLog(@"[RevealLoader] IBARevealLoader class: %@", loaderClass);

    if (loaderClass && [loaderClass respondsToSelector:@selector(startServer)]) {
        NSLog(@"[RevealLoader] Calling +[IBARevealLoader startServer]");
        [loaderClass performSelector:@selector(startServer)];
    } else {
        NSLog(@"[RevealLoader] IBARevealLoader.startServer is unavailable");
    }

    NSLog(@"[RevealLoader] Posting IBARevealRequestStart notification");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"IBARevealRequestStart" object:nil];
    revealServerStarted = YES;
}

static void loadRevealServerIfNeeded(void) {
    if (revealServerLoadAttempted) {
        requestRevealStart();
        return;
    }
    revealServerLoadAttempted = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *libraryPath = nil;

    for (NSString *candidate in revealServerCandidates()) {
        if ([fm fileExistsAtPath:candidate]) {
            libraryPath = candidate;
            break;
        }
    }

    if (!libraryPath) {
        NSLog(@"[RevealLoader] RevealServer not found. Checked paths: %@", revealServerCandidates());
        return;
    }

    NSLog(@"[RevealLoader] Attempting to load RevealServer from %@", libraryPath);
    dlerror();
    void *handle = dlopen([libraryPath UTF8String], RTLD_NOW | RTLD_GLOBAL);
    if (handle) {
        NSLog(@"[RevealLoader] RevealServer loaded successfully for %@, handle=%p", [[NSBundle mainBundle] bundleIdentifier], handle);
        requestRevealStart();
    } else {
        const char *err = dlerror();
        NSLog(@"[RevealLoader] Failed to load RevealServer: %s", err ?: "unknown");
    }
}

static BOOL isRevealEnabledForCurrentApp() {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    return [enabledApps containsObject:bundleID];
}

static void reloadPrefsCallback(CFNotificationCenterRef center,
                                void *observer,
                                CFStringRef name,
                                const void *object,
                                CFDictionaryRef userInfo) {
    loadPreferences();
    NSLog(@"[RevealLoader] Preferences reloaded via Darwin notification.");
}

%ctor {
    @autoreleasepool {
        loadPreferences();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            reloadPrefsCallback,
            CFSTR("com.mikejing.revealloader/ReloadPrefs"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        if (!isRevealEnabledForCurrentApp()) {
            NSLog(@"[RevealLoader] %@ not enabled, skipping Reveal.", [[NSBundle mainBundle] bundleIdentifier]);
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[RevealLoader] Main queue startup for %@", [[NSBundle mainBundle] bundleIdentifier]);
            loadRevealServerIfNeeded();
        });

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            NSLog(@"[RevealLoader] UIApplicationDidBecomeActiveNotification received");
            loadRevealServerIfNeeded();
        }];
    }
}
