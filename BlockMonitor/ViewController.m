//
//  ViewController.m
//  BlockMonitor
//
//  Created by 程薇 on 2020/4/19.
//  Copyright © 2020 kyson. All rights reserved.
//

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController


- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    [[NSNotificationCenter defaultCenter] addObserverForName:@"block_notification" object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        NSDictionary *obj = [note object];
        NSString *blockIntervel = [NSString stringWithFormat:@"%@",obj [@"block_status"]];
        UIAlertView *view = [[UIAlertView alloc] initWithTitle:@"提示" message:[NSString stringWithFormat:@"卡顿了%ld s",blockIntervel.integerValue / 1000 ] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil, nil];
        [view show];
    }];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"卡顿开始");
        for (NSInteger index = 0; index < 10000000 ; ++ index) {
            NSObject *obj = [[NSObject alloc] init];
            [obj description];
        }
        NSLog(@"卡顿结束");

    });
}


@end
