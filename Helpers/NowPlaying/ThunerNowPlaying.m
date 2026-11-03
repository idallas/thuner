// ThUNER's Now Playing helper: what macOS shows in Control Center as playing (any app or website that reports it),
// read through Apple's private MediaRemote framework.
//
// Since macOS 15.4, MediaRemote only answers Apple-signed processes, so ThUNER doesn't load this itself. It runs
// Apple's /usr/bin/perl and has perl load this library and call ThunerNowPlayingMain (see NowPlayingHelper.swift).
// The helper prints one JSON object per line on stdout whenever what's playing changes, takes commands on stdin
// ("playpause", "next", "previous"), and exits when stdin closes (ThUNER quit).
//
// Built by Scripts/build-app.sh into Contents/Frameworks/libThunerNowPlaying.dylib.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);

static MRGetInfo getInfo;
static MRGetPID getPID;
static MRGetIsPlaying getIsPlaying;
static MRSendCommand sendCommand;
static NSString *lastLine;
static NSString *lastArtworkKey;
static BOOL fetchPending;

static void emit(NSDictionary *report) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void scheduleFetch(double delay);

static void fetch(void) {
    fetchPending = NO;
    // Three separate questions, which can straddle a change (the new app with the old track): after any change,
    // ask again a moment later, and the repeat sets it straight.
    getPID(dispatch_get_main_queue(), ^(int pid) {
        getIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
                NSMutableDictionary *report = [NSMutableDictionary dictionary];
                report[@"playing"] = playing ? @YES : @NO;
                if (pid > 0) report[@"pid"] = @(pid);
                NSString *(^string)(NSString *) = ^NSString *(NSString *key) {
                    id value = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]];
                    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
                };
                NSNumber *(^number)(NSString *) = ^NSNumber *(NSString *key) {
                    id value = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]];
                    return [value isKindOfClass:NSNumber.class] ? value : nil;
                };
                if (string(@"Title")) report[@"title"] = string(@"Title");
                if (string(@"Artist")) report[@"artist"] = string(@"Artist");
                if (string(@"Album")) report[@"album"] = string(@"Album");
                if (number(@"Duration").doubleValue > 0) report[@"duration"] = number(@"Duration");

                // Lines repeat for every notification; only pass on real changes (position aside, it always moves).
                NSData *keyData = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
                NSString *line = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
                if ([line isEqualToString:lastLine]) return;
                lastLine = line;
                scheduleFetch(1.0);

                // Where the track is now: elapsed as of the info's timestamp, moved on at its playback rate.
                NSNumber *elapsed = number(@"ElapsedTime");
                if (elapsed) {
                    double position = elapsed.doubleValue;
                    id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if ([stamp isKindOfClass:NSDate.class]) {
                        // Paused, it stays where it stopped (the rate can still say 1).
                        if (playing) position += -[stamp timeIntervalSinceNow] * number(@"PlaybackRate").doubleValue;
                    }
                    report[@"position"] = @(position);
                }
                // The cover only when the track changes, as it can be large.
                NSString *artworkKey = [NSString stringWithFormat:@"%@|%@|%@", report[@"title"], report[@"artist"], report[@"album"]];
                id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([artwork isKindOfClass:NSData.class] && [artwork length] > 0 && ![artworkKey isEqualToString:lastArtworkKey]) {
                    lastArtworkKey = artworkKey;
                    report[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                }
                emit(report);
            });
        });
    });
}

/// Notifications come in bursts (info, playing state, app); fetch once they've settled.
static void scheduleFetch(double delay) {
    if (fetchPending) return;
    fetchPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ fetch(); });
}

static void handleCommand(NSString *command) {
    // MRMediaRemoteCommand: 2 toggle play/pause, 4 next, 5 previous.
    int code = [command isEqualToString:@"playpause"] ? 2 : [command isEqualToString:@"next"] ? 4
        : [command isEqualToString:@"previous"] ? 5 : -1;
    if (code < 0) return;
    Boolean ok = sendCommand(code, nil);
    emit(@{@"command": command, @"ok": ok ? @YES : @NO});
}

/// Called by perl (as an XS sub, so its arguments are perl's and unused). Never returns.
void ThunerNowPlayingMain(void *interpreter, void *cv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = mr ? (MRGetInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    getPID = mr ? (MRGetPID)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    getIsPlaying = mr ? (MRGetIsPlaying)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    sendCommand = mr ? (MRSendCommand)dlsym(mr, "MRMediaRemoteSendCommand") : NULL;
    MRRegister registerForNotifications = mr ? (MRRegister)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
    if (!getInfo || !getPID || !getIsPlaying || !sendCommand || !registerForNotifications) {
        emit(@{@"error": @"MediaRemote isn't available"});
        exit(2);
    }

    registerForNotifications(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { scheduleFetch(0.25); }];
    }

    // Commands, one per line; end of input means ThUNER has gone, so go too.
    static NSMutableData *pending;
    pending = [NSMutableData data];
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{
        char buffer[512];
        ssize_t n = read(STDIN_FILENO, buffer, sizeof buffer);
        if (n <= 0) exit(0);
        [pending appendBytes:buffer length:(NSUInteger)n];
        NSString *text = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding] ?: @"";
        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i + 1 < lines.count; i++) handleCommand(lines[i]);
        pending = [[lines.lastObject dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    });
    dispatch_resume(input);

    emit(@{@"ready": @YES});
    fetch();
    CFRunLoopRun();
    exit(0);
}
