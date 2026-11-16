#import <Foundation/Foundation.h>

@interface Greeter : NSObject
@property (nonatomic, copy) NSString *name;
- (NSString *)greetingForHour:(NSInteger)hour;
@end

@implementation Greeter
- (NSString *)greetingForHour:(NSInteger)hour {
    NSString *part = hour < 12 ? @"morning" : @"afternoon";
    return [NSString stringWithFormat:@"Good %@, %@!", part, self.name ?: @"friend"];
}
@end

int main(void) {
    @autoreleasepool {
        Greeter *g = [Greeter new];
        g.name = @"Peep";
        NSLog(@"%@", [g greetingForHour:9]);
    }
    return 0;
}
