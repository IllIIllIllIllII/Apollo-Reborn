#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/message.h>
#import "ApolloAwardsGiving.h"
#import "ApolloAwardsParsing.h"

// PRODUCTION_TARGET
// PRODUCTION_CHOOSER

@interface TestThing : NSObject
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, copy) NSString *linkID;
@property (nonatomic, strong) id permalink;
@end
@implementation TestThing
@end

static NSUInteger checks;
static void expect(BOOL success) {
    checks++;
    if (!success) { NSLog(@"FAIL: check %lu", (unsigned long)checks); abort(); }
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    TestThing *thing = [TestThing new];
    thing.fullName = @"t3_1q02umz";
    expect([ApolloAwardsGivingURLForThing(thing).absoluteString isEqualToString:@"https://sh.reddit.com/comments/1q02umz/"]);
    thing.permalink = [NSURL URLWithString:@"https://old.reddit.com/r/pics/comments/1q02umz/title/?sort=new#comments"];
    expect([ApolloAwardsGivingURLForThing(thing).absoluteString isEqualToString:@"https://sh.reddit.com/r/pics/comments/1q02umz/title/"]);
    for (NSString *url in @[@"https://example.com/r/pics/comments/1q02umz/",
                            @"https://reddit.com.evil.test/comments/1q02umz/",
                            @"https://www.reddit.com/comments/other/",
                            @"https://user@www.reddit.com/comments/1q02umz/",
                            @"https://www.reddit.com:444/comments/1q02umz/",
                            @"http://www.reddit.com/comments/1q02umz/",
                            @"javascript:alert(1)"]) {
        thing.permalink = url;
        expect([ApolloAwardsGivingURLForThing(thing).absoluteString isEqualToString:@"https://sh.reddit.com/comments/1q02umz/"]);
    }
    thing.fullName = @"t1_nwutqka";
    thing.linkID = @"t3_1q02umz";
    expect([ApolloAwardsGivingURLForThing(thing).absoluteString isEqualToString:@"https://sh.reddit.com/comments/1q02umz/_/nwutqka/?context=0"]);
    thing.linkID = @"1q02umz";
    expect([ApolloAwardsGivingURLForThing(thing).absoluteString isEqualToString:@"https://sh.reddit.com/comments/1q02umz/_/nwutqka/?context=0"]);
    thing.linkID = @"T3_1Q02UMZ";
    expect([ApolloAwardsGivingURLForThing(thing).absoluteString isEqualToString:@"https://sh.reddit.com/comments/1q02umz/_/nwutqka/?context=0"]);
    for (NSString *parent in @[@"", @"t1_wrong", @"../admin", @"1q02umz?give=true", @"abc/def"]) {
        thing.linkID = parent;
        expect(ApolloAwardsGivingURLForThing(thing) == nil);
    }
    for (NSString *fullName in @[@"", @"t5_subreddit", @"t3_../../bad", @"t1_abc?award=1", @"t3_abcdefghijklmnopq"]) {
        thing.fullName = fullName;
        expect(ApolloAwardsGivingURLForThing(thing) == nil);
    }
    expect(ApolloAwardsGivingURLForThing([NSObject new]) == nil);
    expect(ApolloAwardsGivingIsReferenceURL([NSURL URLWithString:@"https://www.reddit.com/policies/econ-terms"]));
    expect(ApolloAwardsGivingIsReferenceURL([NSURL URLWithString:@"https://www.reddit.com/help/gold"]));
    expect(!ApolloAwardsGivingIsReferenceURL([NSURL URLWithString:@"https://www.reddit.com/gold/checkout"]));
    expect(!ApolloAwardsGivingIsReferenceURL([NSURL URLWithString:@"https://www.reddit.com/comments/1q02umz/"]));
    expect(argc == 2);
    JSContext *context = [JSContext new];
    context.exceptionHandler = ^(JSContext *unused, JSValue *exception) {
        (void)unused;
        NSLog(@"JavaScript test failure: %@", exception);
        abort();
    };
    context[@"openChooser"] = [context evaluateScript:[NSString stringWithFormat:@"(async function(fullName){%@})", ApolloAwardsGivingOpenChooserScript()]];
    context[@"isolateChooser"] = [context evaluateScript:[NSString stringWithFormat:@"(async function(isolationStyle,generation,navigationGeneration){%@})", ApolloAwardsGivingIsolateChooserScript()]];
    context[@"isolationStyle"] = ApolloAwardsGivingIsolationStyle();
    context[@"record"] = ^(BOOL success) { expect(success); };
    __block BOOL finished = NO;
    context[@"finish"] = ^{ finished = YES; };
    NSString *script = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
    expect(script.length > 0);
    [context evaluateScript:script];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!finished && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    expect(finished);
    NSLog(@"PASS: %lu giving target and chooser checks", (unsigned long)checks);
} }
