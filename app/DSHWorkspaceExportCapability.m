#import "DSHWorkspaceExportCapability.h"
#import "DSHCapability.h"
#import <UIKit/UIKit.h>
#import <sys/stat.h>

DSH_EXPORTED NSString *const DSHCapabilityWorkspaceExport = @"files.export.workspace";
static const unsigned long long kMaximumExportBytes = 512ULL * 1024 * 1024;
static const NSTimeInterval kPickerTimeout = 120;
static const NSTimeInterval kPresentationGrace = 2;

@interface DSHWorkspaceExportPresentation () <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property (atomic, readwrite, getter=isFinished) BOOL finished;
@property (nonatomic) NSURL *fileURL;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) DSHWorkspaceExportCompletion completion;
@property (nonatomic) UIDocumentPickerViewController *picker;
@property (nonatomic, weak) UIScene *scene;
@property (nonatomic) NSMutableArray *observers;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) BOOL presentationAttempted;
- (instancetype)initWithURL:(NSURL *)url name:(NSString *)name completion:(DSHWorkspaceExportCompletion)completion;
- (void)start;
- (void)finish:(NSString *)state errorCode:(nullable NSString *)errorCode;
@end

/// Accessed exclusively on main; a second request cannot stack save dialogs.
static __weak DSHWorkspaceExportPresentation *sActivePresentation;

@implementation DSHWorkspaceExportCapability

+ (void)registerCapability {
    [DSHCapabilityRegistry.shared registerCapability:
        [[DSHCapability alloc] initWithIdentifier:DSHCapabilityWorkspaceExport
                                         title:@"Workspace file export"
                                       details:@"Saves a verified workspace file to Files. DSH asks about its source, name and size every time."
                                          gate:DSHCapabilityGatePerCall
                              enabledByDefault:YES
                                     available:YES]];
}

+ (NSString *)confirmationDetailForSourcePath:(NSString *)sourcePath name:(NSString *)name bytes:(unsigned long long)bytes {
    return [NSString stringWithFormat:@"Save a file from the DSH workspace?\n\nSource: “%@”\nName: “%@”\nSize: %llu bytes\n\nYou will choose a destination in Files. Saving is reported only after the system finishes exporting the file.",
            DSHDisplayValue(sourcePath, 1024), DSHDisplayValue(name, 255), bytes];
}

+ (DSHConfirmationOutcome)confirmSourcePath:(NSString *)sourcePath name:(NSString *)name bytes:(unsigned long long)bytes {
    return [self confirmSourcePath:sourcePath name:name bytes:bytes cancellationCheck:nil];
}

+ (DSHConfirmationOutcome)confirmSourcePath:(NSString *)sourcePath name:(NSString *)name bytes:(unsigned long long)bytes cancellationCheck:(BOOL (^)(void))cancellationCheck {
    // Blocking on main would prevent the confirmation from ever appearing.
    if (NSThread.isMainThread || ![DSHCapabilityRegistry.shared isEnabled:DSHCapabilityWorkspaceExport])
        return DSHConfirmationUnavailable;
    // Never obtain consent to a shortened or visually different source/name.
    // The transfer store applies the path policy; this protects its UI boundary.
    if (![sourcePath isKindOfClass:NSString.class] || ![name isKindOfClass:NSString.class] ||
        !sourcePath.length || !name.length || sourcePath.length > 1024 || name.length > 255 ||
        ![DSHDisplayValue(sourcePath, 1024) isEqualToString:sourcePath] ||
        ![DSHDisplayValue(name, 255) isEqualToString:name] || bytes > kMaximumExportBytes)
        return DSHConfirmationUnavailable;
    return [DSHCallConfirmation confirmTitle:@"Export workspace file?"
                                     detail:[self confirmationDetailForSourcePath:sourcePath name:name bytes:bytes]
                                 capability:DSHCapabilityWorkspaceExport
                          cancellationCheck:^BOOL {
        return ![DSHCapabilityRegistry.shared isEnabled:DSHCapabilityWorkspaceExport] ||
            (cancellationCheck && cancellationCheck());
    }];
}

+ (DSHWorkspaceExportPresentation *)presentVerifiedFileURL:(NSURL *)fileURL name:(NSString *)name completion:(DSHWorkspaceExportCompletion)completion {
    DSHWorkspaceExportPresentation *presentation = [[DSHWorkspaceExportPresentation alloc] initWithURL:fileURL name:name completion:completion];
    [presentation start];
    return presentation;
}
@end

@implementation DSHWorkspaceExportPresentation

- (instancetype)initWithURL:(NSURL *)url name:(NSString *)name completion:(DSHWorkspaceExportCompletion)completion {
    if ((self = [super init])) {
        _fileURL = url;
        _name = [name copy];
        _completion = [completion copy];
        _observers = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    // A store must retain the operation until its terminal callback. These
    // defensive removals also keep an accidentally abandoned owner bounded.
    [_timer invalidate];
    for (id observer in _observers)
        [NSNotificationCenter.defaultCenter removeObserver:observer];
}

- (NSTimeInterval)pickerTimeout { return kPickerTimeout; }
- (NSTimeInterval)presentationGraceInterval { return kPresentationGrace; }
- (BOOL)applicationIsActive { return UIApplication.sharedApplication.applicationState == UIApplicationStateActive; }

- (UIViewController *)foregroundPresenter {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.hidden || window.windowLevel != UIWindowLevelNormal)
                continue;
            UIViewController *controller = window.rootViewController;
            while (controller.presentedViewController)
                controller = controller.presentedViewController;
            return controller;
        }
    }
    return nil;
}

- (BOOL)presenterIsVisible:(UIViewController *)presenter {
    return presenter.isViewLoaded && presenter.view.window != nil;
}

- (UIDocumentPickerViewController *)pickerForURL:(NSURL *)url {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url] asCopy:YES];
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    return picker;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{ [self startOnMain]; });
}

- (void)startOnMain {
    if (self.finished) return;
    if (sActivePresentation && !sActivePresentation.finished) {
        [self finish:@"unavailable" errorCode:@"export_ui_busy"];
        return;
    }
    if (![DSHCapabilityRegistry.shared isEnabled:DSHCapabilityWorkspaceExport]) {
        [self finish:@"permission_denied" errorCode:@"capability_disabled"];
        return;
    }
    struct stat info;
    if (!self.fileURL.isFileURL || ![self.fileURL.lastPathComponent isEqualToString:self.name] ||
        lstat(self.fileURL.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_size < 0 || (unsigned long long)info.st_size > kMaximumExportBytes) {
        [self finish:@"failed" errorCode:@"invalid_staged_file"];
        return;
    }
    sActivePresentation = self;
    self.startedAt = NSProcessInfo.processInfo.systemUptime;
    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidEnterBackgroundNotification, UISceneDidEnterBackgroundNotification, UISceneDidDisconnectNotification]) {
        id observer = [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            typeof(self) self = weakSelf;
            if (!self || self.finished) return;
            if ([note.name isEqualToString:UIApplicationDidEnterBackgroundNotification] || !self.scene || note.object == self.scene)
                [self finish:@"unavailable" errorCode:@"app_backgrounded"];
        }];
        [self.observers addObject:observer];
    }
    [self.observers addObject:[center addObserverForName:DSHCapabilityRegistryDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        typeof(self) self = weakSelf;
        if (self && ![DSHCapabilityRegistry.shared isEnabled:DSHCapabilityWorkspaceExport])
            [self finish:@"permission_denied" errorCode:@"capability_disabled"];
    }]];
    self.timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self tick];
}

- (void)tick {
    if (self.finished) return;
    if (![DSHCapabilityRegistry.shared isEnabled:DSHCapabilityWorkspaceExport]) {
        [self finish:@"permission_denied" errorCode:@"capability_disabled"];
        return;
    }
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.startedAt;
    if (elapsed >= self.pickerTimeout) {
        [self finish:@"timed_out" errorCode:@"file_picker_timeout"];
        return;
    }
    if (self.presentationAttempted) return;
    if (![self applicationIsActive]) {
        [self finish:@"unavailable" errorCode:@"app_not_active"];
        return;
    }
    UIViewController *presenter = [self foregroundPresenter];
    if (!presenter || ![self presenterIsVisible:presenter]) {
        [self finish:@"unavailable" errorCode:@"no_foreground_presenter"];
        return;
    }
    // The confirmation's Allow action wakes the worker before UIKit finishes
    // dismissing its alert. Wait for that actual transition to finish; never
    // present on top of an unrelated alert, sheet or document picker.
    BOOL transitioning = presenter.isBeingDismissed || presenter.isBeingPresented || presenter.transitionCoordinator != nil;
    if (transitioning) {
        if (elapsed >= self.presentationGraceInterval)
            [self finish:@"unavailable" errorCode:@"presenter_transition_timeout"];
        return;
    }
    if ([presenter isKindOfClass:UIAlertController.class] ||
        [presenter isKindOfClass:UIDocumentPickerViewController.class] ||
        [presenter isKindOfClass:UIActivityViewController.class]) {
        [self finish:@"unavailable" errorCode:@"presenter_busy"];
        return;
    }
    self.scene = presenter.view.window.windowScene;
    self.picker = [self pickerForURL:self.fileURL];
    self.picker.delegate = self;
    self.picker.modalInPresentation = YES;
    self.presentationAttempted = YES;
    // Poll only while UIKit settles the preceding confirmation. Background
    // and gate revocation are event driven while the user chooses a folder.
    self.timer.fireDate = [NSDate dateWithTimeIntervalSinceNow:MAX(0.01, self.pickerTimeout - elapsed)];
    @try {
        __weak typeof(self) weakSelf = self;
        [presenter presentViewController:self.picker animated:YES completion:^{
            typeof(self) self = weakSelf;
            if (self && !self.finished && !self.picker.presentingViewController)
                [self finish:@"unavailable" errorCode:@"picker_not_presented"];
        }];
        self.picker.presentationController.delegate = self;
        if (!self.picker.presentingViewController)
            [self finish:@"unavailable" errorCode:@"picker_not_presented"];
    } @catch (NSException *exception) {
        [self finish:@"failed" errorCode:@"picker_presentation_failed"];
    }
}

- (void)cancel {
    if (NSThread.isMainThread) [self finish:@"cancelled" errorCode:@"export_cancelled"];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self finish:@"cancelled" errorCode:@"export_cancelled"]; });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.finished || controller != self.picker) return;
    if (![DSHCapabilityRegistry.shared isEnabled:DSHCapabilityWorkspaceExport]) {
        [self finish:@"permission_denied" errorCode:@"capability_disabled"];
        return;
    }
    if (urls.count != 1 || ![urls.firstObject isKindOfClass:NSURL.class] || !urls.firstObject.isFileURL) {
        [self finish:@"failed" errorCode:@"invalid_picker_result"];
        return;
    }
    [self finish:@"saved" errorCode:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (controller == self.picker) [self finish:@"cancelled" errorCode:@"user_cancelled"];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (presentationController.presentedViewController == self.picker)
        [self finish:@"cancelled" errorCode:@"user_cancelled"];
}

- (void)finish:(NSString *)state errorCode:(NSString *)errorCode {
    NSAssert(NSThread.isMainThread, @"Export presentation transitions run on main");
    if (self.finished) return;
    self.finished = YES;
    [self.timer invalidate];
    self.timer = nil;
    for (id observer in self.observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [self.observers removeAllObjects];
    if (sActivePresentation == self) sActivePresentation = nil;
    UIDocumentPickerViewController *picker = self.picker;
    picker.delegate = nil;
    picker.presentationController.delegate = nil;
    DSHWorkspaceExportCompletion completion = self.completion;
    self.completion = nil;
    self.picker = nil;
    // The source stays owned by the transfer store until UIKit has dismissed
    // its picker. The returned destination remains entirely under user control.
    if (picker.presentingViewController)
        [picker dismissViewControllerAnimated:NO completion:^{ if (completion) completion(state, errorCode); }];
    else if (completion) completion(state, errorCode);
}
@end
