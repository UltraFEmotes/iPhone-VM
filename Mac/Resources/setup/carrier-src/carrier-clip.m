#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <string.h>

static void PrintHex(NSData *data) {
    const unsigned char *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        printf("%02x", bytes[i]);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        if (argc >= 2 && strcmp(argv[1], "set") == 0) {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (int i = 2; i < argc; i++) {
                [parts addObject:[NSString stringWithUTF8String:argv[i]] ?: @""];
            }
            pasteboard.string = [parts componentsJoinedByString:@" "];
            printf("CLIP_SET\n");
            return 0;
        }

        NSString *text = pasteboard.string ?: @"";
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        printf("CLIP_GET:");
        PrintHex(data);
        printf("\n");
    }
    return 0;
}
