// Loaded into /usr/bin/perl by NowPlayingMonitor. Since macOS 15.4 MediaRemote answers only
// Apple-signed processes, and perl is one: inside it these calls see what is playing. Prints one
// JSON line per change on stdout, and takes commands on stdin ("toggle", "next", "prev",
// "seek <seconds>"), until the app that started it is gone.
//
// Built by the target's "Now Playing bridge" script phase into Contents/Frameworks. It lives
// outside ClangNotch/ because that folder is compiled into the app as a whole.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <unistd.h>

// The selectors below are getters that return autoreleased objects.
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetBoolFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);

static GetInfoFn getInfo;
static GetBoolFn getPlaying;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static unsigned long generation;
static NSData *lastArtSource;
static NSString *lastTrack;
/// Times the line for a new track has been held back waiting for its artwork.
static int artWaits;
static pid_t parent;
/// What the last line said: while playing, the state is read again every 5 s.
static BOOL lastPlaying;

/// The app behind what plays: Safari for its WebKit.GPU process. `MRNowPlayingRequest` is the
/// newer class; macOS 14 may not have it, and then no app is sent.
static NSDictionary *client(void) {
    Class request = NSClassFromString(@"MRNowPlayingRequest");
    if (!request || ![request respondsToSelector:@selector(localNowPlayingPlayerPath)]) return @{};
    id path = [request performSelector:@selector(localNowPlayingPlayerPath)];
    id c = [path respondsToSelector:@selector(client)] ? [path performSelector:@selector(client)] : nil;
    if (!c) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if ([c respondsToSelector:@selector(processIdentifier)]) {
        int pid = ((int (*)(id, SEL))objc_msgSend)(c, @selector(processIdentifier));
        if (pid > 0) out[@"pid"] = @(pid);
    }
    for (NSString *key in @[@"bundleIdentifier", @"parentApplicationBundleIdentifier", @"displayName"]) {
        SEL sel = NSSelectorFromString(key);
        if (![c respondsToSelector:sel]) continue;
        id value = [c performSelector:sel];
        if ([value isKindOfClass:[NSString class]] && [value length]) out[key] = value;
    }
    return out;
}

/// A 160 px PNG of the artwork, only when it differs from the one last sent for this track: a
/// video thumbnail came as 363 KB of TIFF, and the same artwork repeats with every info change.
/// A new track always gets it again (the next song of an album has the same artwork, and the
/// app keeps a picture only within one track).
static NSString *artwork(NSData *data) {
    if (!data.length || [data isEqualToData:lastArtSource]) return nil;
    lastArtSource = data;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                              (id)kCGImageSourceThumbnailMaxPixelSize: @160,
                              (id)kCGImageSourceCreateThumbnailWithTransform: @YES};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return nil;
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(image);
    return png.length ? [png base64EncodedStringWithOptions:0] : nil;
}

static void put(NSMutableDictionary *o, NSString *key, id value) {
    if ([value isKindOfClass:[NSString class]] && [value length]) o[key] = value;
}

static void emit(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        getPlaying(dispatch_get_main_queue(), ^(BOOL playing) {
            NSMutableDictionary *o = [NSMutableDictionary dictionary];
            o[@"playing"] = @(playing);
            lastPlaying = playing;
            put(o, @"title", info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
            put(o, @"artist", info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
            NSDictionary *c = client();
            NSString *track = [NSString stringWithFormat:@"%@\x1f%@\x1f%@", c[@"parentApplicationBundleIdentifier"] ?: c[@"bundleIdentifier"],
                               info[@"kMRMediaRemoteNowPlayingInfoTitle"], info[@"kMRMediaRemoteNowPlayingInfoArtist"]];
            BOOL newTrack = ![track isEqualToString:lastTrack];
            // A new track's title comes a notification before its artwork, and the app showed the
            // playing app's icon in between (user's recording, 2026-11-12). When macOS says there
            // is artwork, wait for it a little (up to 0.6 s) and send both at once; a notification
            // in the meantime takes over from this wait.
            NSData *artData = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            BOOL artComing = info[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"] || info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
            if (newTrack && !artData.length && artComing && artWaits < 5) {
                artWaits++;
                unsigned long mine = generation;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    if (mine == generation) emit();
                });
                return;
            }
            artWaits = 0;
            if (newTrack) { lastTrack = track; lastArtSource = nil; }
            put(o, @"bundle", c[@"bundleIdentifier"]);
            put(o, @"parent", c[@"parentApplicationBundleIdentifier"]);
            put(o, @"app", c[@"displayName"]);
            if (c[@"pid"]) o[@"pid"] = c[@"pid"];
            // Where playback was at `ts`; the app moves it on by `rate` from there.
            for (NSString *key in @[@"Duration", @"ElapsedTime", @"PlaybackRate"]) {
                id value = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]];
                if ([value isKindOfClass:[NSNumber class]]) o[key.lowercaseString] = value;
            }
            NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([stamp isKindOfClass:[NSDate class]]) o[@"ts"] = @(stamp.timeIntervalSince1970);
            NSString *art = artwork(info[@"kMRMediaRemoteNowPlayingInfoArtworkData"]);
            if (art) o[@"art"] = art;
            NSData *json = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
            if (!json) return;
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            fflush(stdout);
        });
    });
}

/// Notifications come in bursts of two or three per change: answer the last one.
static void schedule(void) {
    unsigned long mine = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (mine == generation) emit();
    });
}

/// MediaRemote's command numbers.
enum { CommandTogglePlayPause = 2, CommandNextTrack = 4, CommandPreviousTrack = 5 };

static void command(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *verb = parts.firstObject;
    if ([verb isEqualToString:@"toggle"]) sendCommand(CommandTogglePlayPause, nil);
    else if ([verb isEqualToString:@"next"]) sendCommand(CommandNextTrack, nil);
    else if ([verb isEqualToString:@"prev"]) sendCommand(CommandPreviousTrack, nil);
    else if ([verb isEqualToString:@"seek"] && parts.count > 1 && setElapsed) setElapsed(parts[1].doubleValue);
}

/// Commands, one per line. The end of stdin is the app gone: exit.
static void listen(void) {
    static NSMutableData *pending;
    pending = [NSMutableData data];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        char chunk[512];
        ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
        if (n <= 0) exit(0);
        [pending appendBytes:chunk length:(NSUInteger)n];
        for (;;) {
            NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, pending.length)];
            if (newline.location == NSNotFound) break;
            NSString *line = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, newline.location)] encoding:NSUTF8StringEncoding];
            [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            if (line.length) command(line);
        }
    });
    dispatch_resume(source);
    // Kept alive by the static below.
    static dispatch_source_t keep;
    keep = source;
}

/// Called by perl as an XSUB; its arguments are ignored. Returns only by exiting.
void cn_stream(void) {
    parent = getppid();
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fputs("no MediaRemote\n", stderr); exit(2); }
    getInfo = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = (GetBoolFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    RegisterFn reg = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    sendCommand = (SendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    if (!getInfo || !getPlaying || !reg || !sendCommand) { fputs("MediaRemote calls missing\n", stderr); exit(2); }
    listen();
    reg(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { schedule(); }];
    }
    // The app was killed: nothing would ever write to the closed pipe, so look for it.
    // While something plays, read it again too: a stop whose notification never came left the
    // pinned card playing on with its time running (user, 2026-11-12). The same state sends the
    // same line (artwork goes only when it changes), which the app ignores.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        if (getppid() != parent) exit(0);
        if (lastPlaying) schedule();
    });
    dispatch_resume(timer);
    emit();
    CFRunLoopRun();
    exit(0);
}
