//
//  AVStreamDataParserProbe.m
//  Reynard
//
//  Answers one question, once, at launch: can this device do MSE +
//  FairPlay the way WebKit does it?
//
//  Public AVFoundation cannot. Only AVURLAsset conforms to
//  AVContentKeyRecipient (AVAsset.h:998 in the iOS 26.2 SDK), so an
//  AVContentKeySession has nothing to attach to when the samples come
//  from a SourceBuffer rather than a URL. That is why every MSE key
//  request this pipeline has ever seen parked and never replayed.
//  WebKit's way around it is AVStreamDataParser: absent from every
//  public header, present in the shipped framework, and named by the one
//  exported constant AVStreamDataParserContentKeyRequestProtocolVersionsKey.
//
//  Output goes to stderr, which is the channel device captures record -
//  os_log does not reach them. So the answer arrives in
//  reynard_stdout.txt with everything else, and needs no SSH, no loose
//  binary and no separate signing step.
//
//  Nothing here assumes a selector. The parser's interface is
//  undocumented and the names below are only what WebKit is believed to
//  use; the probe dumps the real method list and routes the delegate
//  through forwardInvocation:, so a wrong guess shows up as a missing
//  selector in the dump rather than as a silent no-op.
//
//  Steps 1-5 need no media and run unconditionally. Step 6 needs an
//  encrypted init segment and is skipped when none is present, because
//  the first five answer the architectural question on their own:
//  whether the class exists, whether it is a legal content key
//  recipient, and what its interface actually is.
//

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "AVStreamDataParserProbe.h"

// Matches avLog and printf_stderr. Flushed every line: this runs at
// launch, and a process that dies early still gets its answer out.
static void ProbeLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  fprintf(stderr, "parserProbe: %s\n", line.UTF8String);
  fflush(stderr);
}

#pragma mark - A delegate that logs whatever it is sent

// Implements none of the output protocol and intercepts all of it.
// respondsToSelector: says yes to anything the parser might call, and
// forwardInvocation: records it - so a callback whose name nobody
// expected is still reported.
@interface ProbeDelegate : NSObject
@property(nonatomic, strong) NSMutableArray<NSString *> *calls;
@end

@implementation ProbeDelegate

- (instancetype)init {
  self = [super init];
  if (self) {
    _calls = [NSMutableArray array];
  }
  return self;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
  if ([super respondsToSelector:aSelector]) {
    return YES;
  }
  return [NSStringFromSelector(aSelector) hasPrefix:@"streamDataParser"];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
  NSMethodSignature *signature = [super methodSignatureForSelector:aSelector];
  if (signature) {
    return signature;
  }
  // The real signatures are unknown. Every callback observed in WebKit
  // returns void and takes objects, so a generic object signature is
  // enough to receive the call and report it; extra arguments are never
  // read.
  NSString *name = NSStringFromSelector(aSelector);
  NSUInteger colons = [[name componentsSeparatedByString:@":"] count] - 1;
  NSMutableString *types = [NSMutableString stringWithString:@"v@:"];
  for (NSUInteger i = 0; i < colons; i++) {
    [types appendString:@"@"];
  }
  return [NSMethodSignature signatureWithObjCTypes:types.UTF8String];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
  NSString *name = NSStringFromSelector(invocation.selector);
  [self.calls addObject:name];
  ProbeLog(@"  <- parser called delegate: %@", name);

  // The callback that matters is whichever carries content key
  // initialisation data. Reporting its payload size distinguishes a real
  // key request from a parse callback that merely sounds like one.
  if ([name containsString:@"ContentKey"]) {
    NSUInteger count = invocation.methodSignature.numberOfArguments;
    for (NSUInteger i = 2; i < count; i++) {
      const char *type = [invocation.methodSignature getArgumentTypeAtIndex:i];
      if (type[0] != '@') {
        continue;
      }
      __unsafe_unretained id argument = nil;
      [invocation getArgument:&argument atIndex:i];
      if ([argument isKindOfClass:[NSData class]]) {
        ProbeLog(@"     CONTENT KEY INIT DATA: %lu bytes",
                 (unsigned long)[(NSData *)argument length]);
      }
    }
  }
}

@end

#pragma mark - Probe

static void DumpMethods(Class cls) {
  unsigned int count = 0;
  Method *methods = class_copyMethodList(cls, &count);
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (unsigned int i = 0; i < count; i++) {
    [names addObject:NSStringFromSelector(method_getName(methods[i]))];
  }
  free(methods);
  [names sortUsingSelector:@selector(caseInsensitiveCompare:)];
  ProbeLog(@"instance methods (%u):", count);
  for (NSString *name in names) {
    ProbeLog(@"    %@", name);
  }
}

// The encrypted init segment, if one was dropped into the app's
// Documents directory. Apple ships it in the FairPlay Streaming Server
// SDK under Client/FairPlay Streaming in Safari/FPS With MSE/content.
// Optional on purpose - the first five steps answer the architectural
// question without it.
static NSData *ProbeSegment(void) {
  NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  if (documents.count == 0) {
    return nil;
  }
  NSString *path = [documents.firstObject
      stringByAppendingPathComponent:
          @"elementary-stream-video-header-keyid-1.m4v"];
  return [NSData dataWithContentsOfFile:path];
}

void ReynardRunAVStreamDataParserProbe(void) {
  static BOOL sHasRun = NO;
  if (sHasRun) {
    return;
  }
  sHasRun = YES;

  @autoreleasepool {
    ProbeLog(@"=== 1. does AVStreamDataParser exist at runtime? ===");
    Class parserClass = NSClassFromString(@"AVStreamDataParser");
    if (!parserClass) {
      ProbeLog(@"ABSENT - the SPI is gone on this OS. MSE+FairPlay has no "
               @"route and the streaming services are unreachable.");
      return;
    }
    ProbeLog(@"present: %@", NSStringFromClass(parserClass));

    ProbeLog(@"=== 2. does it conform to AVContentKeyRecipient? ===");
    Protocol *recipient = objc_getProtocol("AVContentKeyRecipient");
    if (!recipient) {
      ProbeLog(@"AVContentKeyRecipient protocol not found at runtime");
    } else {
      ProbeLog(@"%@", class_conformsToProtocol(parserClass, recipient)
                          ? @"YES - declared a content key recipient"
                          : @"NO - conformance not declared on the class "
                            @"(addContentKeyRecipient: below is the real test)");
    }

    ProbeLog(@"=== 3. what is its real interface? ===");
    DumpMethods(parserClass);

    ProbeLog(@"=== 4. instantiate ===");
    id parser = [[parserClass alloc] init];
    if (!parser) {
      ProbeLog(@"alloc/init returned nil");
      return;
    }
    ProbeLog(@"instantiated %@", parser);

    ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
    SEL setDelegate = NSSelectorFromString(@"setDelegate:");
    if ([parser respondsToSelector:setDelegate]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [parser performSelector:setDelegate withObject:delegate];
#pragma clang diagnostic pop
      ProbeLog(@"delegate set");
    } else {
      ProbeLog(@"NO setDelegate: - see the method dump above for the real name");
    }

    ProbeLog(@"=== 5. add to an AVContentKeySession ===");
    AVContentKeySession *session = [AVContentKeySession
        contentKeySessionWithKeySystem:AVContentKeySystemFairPlayStreaming];
    if (!session) {
      ProbeLog(@"could not create a FairPlay AVContentKeySession");
      return;
    }
    @try {
      [session addContentKeyRecipient:(id)parser];
      ProbeLog(@"addContentKeyRecipient: ACCEPTED - recipients now %lu. This "
               @"is the answer that matters: a parser CAN receive content "
               @"keys, so MSE+FairPlay has a route.",
               (unsigned long)session.contentKeyRecipients.count);
    } @catch (NSException *exception) {
      ProbeLog(@"addContentKeyRecipient: REFUSED - %@: %@", exception.name,
               exception.reason);
      ProbeLog(@"MSE+FairPlay has no route through this class.");
      return;
    }

    ProbeLog(@"=== 6. feed an encrypted init segment ===");
    NSData *segment = ProbeSegment();
    if (!segment) {
      ProbeLog(@"no segment in Documents - stopping here. Steps 1-5 have "
               @"answered whether the architecture exists; drop "
               @"elementary-stream-video-header-keyid-1.m4v there to test "
               @"whether a key request actually fires.");
      return;
    }
    ProbeLog(@"read %lu bytes", (unsigned long)segment.length);

    SEL append = NSSelectorFromString(@"appendStreamData:");
    if (![parser respondsToSelector:append]) {
      ProbeLog(@"NO appendStreamData: - check the dump for the real name");
      return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [parser performSelector:append withObject:segment];
#pragma clang diagnostic pop
    ProbeLog(@"appended; callbacks arrive asynchronously and are logged above "
             @"as they land");

    // Deliberately no run loop spin. This is called from the app's own
    // startup on the main thread, and blocking it is the one thing that
    // earns a scene-update watchdog kill - which this codebase has
    // already taken once today. The callbacks log themselves whenever
    // they arrive.
  }
}
