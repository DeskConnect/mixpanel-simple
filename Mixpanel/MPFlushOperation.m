//
//  MPFlushOperation.m
//  mixpanel-simple
//
//  Created by Conrad Kramer on 11/19/14.
//  Copyright (c) 2014 DeskConnect. All rights reserved.
//

#import "MPFlushOperation.h"
#import "MPTracker.h"
#import "MPUtilities.h"

extern NSString * const MPEventQueueKey;

@interface MPFlushOperation ()

@property (nonatomic, getter=hasStarted) BOOL started;
@property (nonatomic, getter=isFinished) BOOL finished;

@end

@implementation MPFlushOperation {
    NSFileHandle *_handle;
    NSURLSessionTask *_task;
    BOOL _started;
}

@synthesize cacheURL = _cacheURL;
@synthesize finished = _finished;

+ (NSSet *)keyPathsForValuesAffectingIsFinished {
    return [NSSet setWithObjects:@"finished", nil];
}

+ (NSSet *)keyPathsForValuesAffectingIsExecuting {
    return [NSSet setWithObjects:@"finished", @"started", nil];
}

- (instancetype)init {
    return [self initWithCacheURL:nil];
}

- (instancetype)initWithCacheURL:(NSURL *)cacheURL {
    NSParameterAssert(cacheURL.fileURL);
    self = [super init];
    if (self) {
        NSError *error = nil;
        _handle = [NSFileHandle fileHandleForUpdatingURL:cacheURL error:&error];
        if (!_handle) {
            NSLog(@"%@: Error: %@", self, error.localizedDescription);
            return nil;
        }

        _cacheURL = [cacheURL copy];
    }
    return self;
}

- (void)cancel {
    [super cancel];
    [_task cancel];
    if (flock(_handle.fileDescriptor, LOCK_UN) == -1)
        NSLog(@"%@: Error: Could not unlock file descriptor", self);
#if MIXPANEL_INFO_LOG
    NSLog(@"%@: Cancelling flush operation", self);
#endif
    self.finished = YES;
}

- (void)start {
    __block dispatch_block_t block = ^{
        if (flock(_handle.fileDescriptor, LOCK_EX) == -1) {
            NSLog(@"%@: Error: Could not lock file descriptor", self);
            return;
        }
        
        if (self.cancelled) {
            if (flock(_handle.fileDescriptor, LOCK_UN) == -1)
                NSLog(@"%@: Error: Could unlock file descriptor", self);
            return;
        }
        
        FILE *file;
        if ((file = fopen(_cacheURL.fileSystemRepresentation, "r")) == NULL) {
            NSLog(@"%@: Error: Could not open file descriptor", self);
            if (flock(_handle.fileDescriptor, LOCK_UN) == -1)
                NSLog(@"%@: Error: Could unlock file descriptor", self);
            return;
        }
        
        char start = '[';
        char delim = ',';
        char end = ']';
        
        NSMutableData *body = [NSMutableData new];
        [body appendBytes:&start length:1];
        
        int line = 0;
        ssize_t length = -1;
        size_t n = 1024;
        char *lineptr = malloc(length);
        off_t offset = 0;
        while ((length = getline(&lineptr, &n, file)) > 0 && line < 50 && !self.cancelled) {
            offset += length;
            
            NSError *error = nil;
            [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:lineptr length:length freeWhenDone:NO] options:NSJSONReadingAllowFragments error:&error];
            if (error) {
                NSLog(@"%@: Error: Line is not valid JSON, skipping", self);
                continue;
            }
            [body appendBytes:lineptr length:(length - 1)];
            [body appendBytes:&delim length:1];
            line++;
        }
        
        [body replaceBytesInRange:NSMakeRange(body.length - 1, 1) withBytes:&end length:1];
        fclose(file);
        
        if (line == 0 || self.cancelled) {
#if MIXPANEL_INFO_LOG
            NSLog(@"%@: No events to upload", self);
#endif
            if (flock(_handle.fileDescriptor, LOCK_UN) == -1)
                NSLog(@"%@: Error: Could unlock file descriptor", self);
            return;
        }
        
        NSURLRequest *request = MPURLRequestForEventData(body);
        if (!request || self.cancelled) {
            NSLog(@"%@: Error: Failed to create request", self);
            if (flock(_handle.fileDescriptor, LOCK_UN) == -1)
                NSLog(@"%@: Error: Could unlock file descriptor", self);
            return;
        }
        
        __block NSError *error = nil;
        __block NSHTTPURLResponse *response = nil;
        __block NSData *responseData = nil;
        
        if ([NSURLSession class]) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            _task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *sessionData, NSURLResponse *sessionResponse, NSError *sessionError) {
                _task = nil;
                responseData = sessionData;
                response = (NSHTTPURLResponse *)sessionResponse;
                error = sessionError;
                dispatch_semaphore_signal(semaphore);
            }];
            [_task resume];
            dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
#ifndef __WATCH_OS_VERSION_MIN_REQUIRED
        } else {
            responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#endif
        }
        
        NSIndexSet *acceptableCodes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(200, 100)];
        if (error || !responseData.length || ![acceptableCodes containsIndex:response.statusCode]) {
            NSLog(@"%@: Error: Request failed: %@", self, error.localizedDescription);
            if (flock(_handle.fileDescriptor, LOCK_UN) == -1)
                NSLog(@"%@: Error: Could unlock file descriptor", self);
            return;
        }
        
        if ([[[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] integerValue] != 1) {
            NSLog(@"%@: Error: Not all events accepted by server", self);
        }
        
        [_handle seekToFileOffset:offset];
        NSData *fileData = [_handle readDataToEndOfFile];
        [_handle seekToFileOffset:0];
        [_handle writeData:fileData];
        [_handle truncateFileAtOffset:fileData.length];
        
        if (flock(_handle.fileDescriptor, LOCK_UN) == -1)
            NSLog(@"%@: Error: Could unlock file descriptor", self);
#if MIXPANEL_INFO_LOG
        NSLog(@"%@: Successfully uploaded %i events", self, line + 1);
#endif
    };
    
    self.started = YES;
    
#if TARGET_OS_IPHONE
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    if ([processInfo respondsToSelector:@selector(performExpiringActivityWithReason:usingBlock:)]) {
        // This is to work around rdar://26359403, where the expiring activity block is retained forever
        __weak __typeof__(self) weakSelf = self;
        [processInfo performExpiringActivityWithReason:@"is.workflow.my.app.mixpanel.flush" usingBlock:^(BOOL expired) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (expired)
                return [strongSelf cancel];
            
            block();
            block = nil;
            
            strongSelf.finished = YES;
        }];
    } else {
#endif
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            block();
            self.finished = YES;
        });
#if TARGET_OS_IPHONE
    }
#endif
}

- (BOOL)isConcurrent {
    return YES;
}

- (BOOL)isAsynchronous {
    return YES;
}

- (BOOL)isExecuting {
    return self.started && !self.finished;
}

@end
