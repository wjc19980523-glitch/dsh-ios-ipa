//
//  DSHLogViewController.m
//  DSH
//

#import "DSHLogViewController.h"
#import "DSHHarness.h"
#import "DSHLifecycleDiagnostics.h"

@interface DSHLogViewController ()
@property (nonatomic) DSHLogBuffer *log;
@property (nonatomic) UITextView *textView;
@property (nonatomic) NSURL *sharedAttachment;
@end

@implementation DSHLogViewController

- (instancetype)initWithLog:(DSHLogBuffer *)log {
    if (self = [super initWithNibName:nil bundle:nil]) {
        _log = log;
        self.title = @"Server Log";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *tv = [UITextView new];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.textColor = UIColor.labelColor;
    tv.backgroundColor = UIColor.systemBackgroundColor;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    tv.alwaysBounceVertical = YES;
    tv.accessibilityIdentifier = @"dsh.logview";
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    self.textView = tv;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)],
    ];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clear)];
    self.navigationItem.rightBarButtonItems[1].accessibilityIdentifier = @"dsh.log.share";
    self.navigationItem.leftBarButtonItem.accessibilityIdentifier = @"dsh.log.clear";

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:DSHLogBufferDidChangeNotification object:self.log];
    [self refresh];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.sharedAttachment) [NSFileManager.defaultManager removeItemAtURL:self.sharedAttachment error:nil];
}

- (void)refresh {
    NSString *text = [NSString stringWithFormat:@"%@\n\nSaved diagnostics: metadata only; guest free-form output below is excluded from the shared attachment.\n\n%@",
                      self.log.diagnosticSummary, [self.log.lines componentsJoinedByString:@"\n"]];
    BOOL atBottom = self.textView.contentOffset.y >= self.textView.contentSize.height - self.textView.bounds.size.height - 40;
    self.textView.text = text;
    if (atBottom && text.length)
        [self.textView scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)clear {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear diagnostics?"
        message:@"Saved reports contain local metadata only. Deleting them does not change sessions, settings or workspace files."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear visible log" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self.log clear]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete saved diagnostics" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [self.log clearRetainedDiagnostics]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)share:(UIBarButtonItem *)sender {
    if (self.log == DSHHarness.shared.log) [DSHLifecycleDiagnostics recordEvent:@"diagnosticReportExported" harness:DSHHarness.shared];
    NSError *error = nil;
    NSURL *attachment = [self.log writeDiagnosticAttachmentWithError:&error];
    if (!attachment) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could not create diagnostics"
            message:@"The local attachment could not be written. Your app data has not been changed. Try again when device storage is available."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.sharedAttachment = attachment;
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[attachment] applicationActivities:nil];
    __weak typeof(self) weakSelf = self;
    vc.completionWithItemsHandler = ^(__unused UIActivityType activityType, __unused BOOL completed, __unused NSArray *items, __unused NSError *activityError) {
        [NSFileManager.defaultManager removeItemAtURL:attachment error:nil];
        if ([weakSelf.sharedAttachment isEqual:attachment]) weakSelf.sharedAttachment = nil;
    };
    vc.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:vc animated:YES completion:nil];
}

@end
