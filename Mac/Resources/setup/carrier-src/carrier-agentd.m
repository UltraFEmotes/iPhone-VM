#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString * const BrokerBase = @"http://192.168.178.1:8088";
static NSString * const CarrierHome = @"/var/mobile/Library/InfernoCarrier";
static NSString * const ConfigPath = @"/var/mobile/Library/InfernoCarrier/config.json";
static NSString * const StatePath = @"/var/mobile/Library/InfernoCarrier/state.json";
static NSString * const HelperPath = @"/var/mobile/Library/InfernoCarrier/bin/carrier-msg";

static NSString *StringValue(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return [value stringValue];
    }
    return @"";
}

static NSString *CleanNumber(id value) {
    NSString *text = [StringValue(value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([[text uppercaseString] isEqualToString:@"ADMIN"]) {
        return @"ADMIN";
    }
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c >= '0' && c <= '9') || c == '+') {
            [clean appendFormat:@"%C", c];
        }
    }
    return clean;
}

static NSMutableDictionary *LoadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return [NSMutableDictionary dictionary];
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if ([object isKindOfClass:NSMutableDictionary.class]) {
        return object;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        return [object mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}

static void SaveJSON(NSDictionary *json, NSString *path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    [data writeToFile:path atomically:YES];
}

static NSString *QueryEscape(NSString *value) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&+=?"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSDictionary *HTTPJSON(NSString *method, NSString *path, NSDictionary *body) {
    NSURL *url = [NSURL URLWithString:[BrokerBase stringByAppendingString:path]];
    if (!url) {
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:4.0];
    request.HTTPMethod = method;
    if (body) {
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    __block NSInteger status = 0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error) {
            responseData = data;
            if ([response isKindOfClass:NSHTTPURLResponse.class]) {
                status = ((NSHTTPURLResponse *)response).statusCode;
            }
        }
        dispatch_semaphore_signal(semaphore);
    }] resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (!responseData || status < 200 || status >= 300) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString *ShellQuote(NSString *value) {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

static NSString *RunShell(NSString *command) {
    FILE *pipe = popen(command.UTF8String, "r");
    if (!pipe) {
        return @"";
    }
    NSMutableData *data = [NSMutableData data];
    char buffer[4096];
    while (!feof(pipe)) {
        size_t n = fread(buffer, 1, sizeof(buffer), pipe);
        if (n > 0) {
            [data appendBytes:buffer length:n];
        }
    }
    pclose(pipe);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *StringFromHex(NSString *hex) {
    NSMutableData *data = [NSMutableData data];
    NSUInteger i = 0;
    while (i + 1 < hex.length) {
        NSString *pair = [hex substringWithRange:NSMakeRange(i, 2)];
        unsigned int value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if ([scanner scanHexInt:&value]) {
            unsigned char byte = (unsigned char)value;
            [data appendBytes:&byte length:1];
        }
        i += 2;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSInteger IntegerInState(NSDictionary *state, NSString *key, NSInteger fallback) {
    id value = state[key];
    if ([value respondsToSelector:@selector(integerValue)]) {
        return [value integerValue];
    }
    return fallback;
}

static NSInteger MaxSentRowID(void) {
    NSString *out = RunShell([NSString stringWithFormat:@"%@ max", ShellQuote(HelperPath)]);
    return [[out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] integerValue];
}

static void DeliverBrokerMessages(NSMutableDictionary *state, NSString *number) {
    if (number.length == 0) {
        return;
    }
    NSInteger since = IntegerInState(state, @"brokerSince", 0);
    NSString *path = [NSString stringWithFormat:@"/api/messages?since=%ld&number=%@", (long)since, QueryEscape(number)];
    NSDictionary *response = HTTPJSON(@"GET", path, nil);
    NSArray *messages = [response[@"messages"] isKindOfClass:NSArray.class] ? response[@"messages"] : @[];
    NSInteger high = since;
    for (id item in messages) {
        if (![item isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *message = item;
        NSInteger messageID = [message[@"id"] respondsToSelector:@selector(integerValue)] ? [message[@"id"] integerValue] : 0;
        high = MAX(high, messageID);
        NSString *from = CleanNumber(message[@"from"]);
        NSString *to = CleanNumber(message[@"to"]);
        NSString *source = StringValue(message[@"source"]);
        if (![to isEqualToString:number]) {
            continue;
        }
        if ([source isEqualToString:@"vm"] && [from isEqualToString:number]) {
            continue;
        }

        NSString *kind = StringValue(message[@"kind"]);
        if ([kind isEqualToString:@"call"]) {
            RunShell([NSString stringWithFormat:@"%@ call %@", ShellQuote(HelperPath), ShellQuote(from)]);
        } else {
            NSString *body = StringValue(message[@"body"]);
            RunShell([NSString stringWithFormat:@"%@ send %@ %@", ShellQuote(HelperPath), ShellQuote(from), ShellQuote(body)]);
        }
    }
    state[@"brokerSince"] = @(high);
}

static void PublishVMReplies(NSMutableDictionary *state, NSString *number) {
    if (number.length == 0) {
        return;
    }
    if (![state[@"smsBootstrapped"] boolValue]) {
        state[@"smsSince"] = @(MaxSentRowID());
        state[@"smsBootstrapped"] = @YES;
        return;
    }

    NSInteger since = IntegerInState(state, @"smsSince", 0);
    NSString *out = RunShell([NSString stringWithFormat:@"%@ poll %ld", ShellQuote(HelperPath), (long)since]);
    NSArray<NSString *> *lines = [out componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSInteger high = since;
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length == 0) {
            continue;
        }
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@":"];
        if (parts.count != 3) {
            continue;
        }
        NSInteger rowID = [parts[0] integerValue];
        NSString *to = CleanNumber(StringFromHex(parts[1]));
        NSString *body = StringFromHex(parts[2]);
        if (rowID <= since || to.length == 0 || body.length == 0) {
            continue;
        }
        NSDictionary *payload = @{
            @"from": number,
            @"to": to,
            @"body": body,
            @"kind": @"text",
            @"source": @"vm",
            @"client_id": [NSString stringWithFormat:@"vm-%@-%ld", number, (long)rowID],
        };
        HTTPJSON(@"POST", @"/api/send", payload);
        high = MAX(high, rowID);
    }
    state[@"smsSince"] = @(high);
}

static NSString *ClipboardText(void) {
    return [UIPasteboard generalPasteboard].string ?: @"";
}

static void SetClipboardText(NSString *text) {
    [UIPasteboard generalPasteboard].string = text ?: @"";
}

static void SyncClipboard(NSMutableDictionary *state) {
    NSDictionary *remote = HTTPJSON(@"GET", @"/clip", nil);
    NSInteger remoteSeq = [remote[@"seq"] respondsToSelector:@selector(integerValue)] ? [remote[@"seq"] integerValue] : 0;
    NSInteger seenSeq = IntegerInState(state, @"clipSeq", 0);
    NSString *remoteSource = StringValue(remote[@"source"]);
    NSString *remoteText = StringValue(remote[@"text"]);
    if (remoteSeq > seenSeq) {
        state[@"clipSeq"] = @(remoteSeq);
        if ([remoteSource isEqualToString:@"mac"] && ![remoteText isEqualToString:ClipboardText()]) {
            SetClipboardText(remoteText);
            state[@"lastLocalClip"] = remoteText;
        }
    }

    NSString *local = ClipboardText();
    NSString *lastLocal = StringValue(state[@"lastLocalClip"]);
    if (local.length > 0 && ![local isEqualToString:lastLocal]) {
        NSDictionary *posted = HTTPJSON(@"POST", @"/clip", @{@"text": local, @"source": @"vm"});
        state[@"lastLocalClip"] = local;
        if ([posted[@"seq"] respondsToSelector:@selector(integerValue)]) {
            state[@"clipSeq"] = @([posted[@"seq"] integerValue]);
        }
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:CarrierHome
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSMutableDictionary *config = LoadJSON(ConfigPath);
        NSMutableDictionary *state = LoadJSON(StatePath);

        NSString *cliNumber = @"";
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--number") == 0 && i + 1 < argc) {
                cliNumber = [NSString stringWithUTF8String:argv[++i]] ?: @"";
            }
        }

        NSString *number = CleanNumber(cliNumber.length > 0 ? cliNumber : (StringValue(config[@"number"]).length > 0 ? config[@"number"] : state[@"number"]));
        if (number.length > 0) {
            state[@"number"] = number;
            SaveJSON(state, StatePath);
        }

        const char *numberCString = number ? number.UTF8String : "";
        printf("carrier-agentd started number=%s\n", numberCString);
        fflush(stdout);

        while (1) {
            @autoreleasepool {
                NSMutableDictionary *freshConfig = LoadJSON(ConfigPath);
                NSString *configured = CleanNumber(freshConfig[@"number"]);
                if (configured.length > 0 && ![configured isEqualToString:number]) {
                    number = configured;
                    state[@"number"] = number;
                    state[@"smsBootstrapped"] = @NO;
                }
                HTTPJSON(@"GET", @"/api/health", nil);
                DeliverBrokerMessages(state, number);
                PublishVMReplies(state, number);
                SyncClipboard(state);
                SaveJSON(state, StatePath);
            }
            sleep(1);
        }
    }
    return 0;
}
