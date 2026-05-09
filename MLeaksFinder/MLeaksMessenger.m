/**
 * Tencent is pleased to support the open source community by making MLeaksFinder available.
 *
 * Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
 *
 * Licensed under the BSD 3-Clause License (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at
 *
 * https://opensource.org/licenses/BSD-3-Clause
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
 */

#import "MLeaksMessenger.h"
#import "NSObject+MemoryLeak.h"
#import <UIKit/UIKit.h>

static NSMutableArray *pendingAlertContexts;
static BOOL isPresentingAlert;

@interface MLeaksMessengerAlertContext : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *additionalButtonTitle;
@property (nonatomic, copy) MLeaksMessengerActionHandler actionHandler;
@end

@implementation MLeaksMessengerAlertContext
@end

@implementation MLeaksMessenger

+ (UIViewController *)topViewController {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
            if (keyWindow) {
                break;
            }
        }
    }
    if (!keyWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    }
    
    UIViewController *viewController = keyWindow.rootViewController;
    while (viewController) {
        if (viewController.presentedViewController) {
            viewController = viewController.presentedViewController;
            continue;
        }
        if ([viewController isKindOfClass:[UINavigationController class]]) {
            UIViewController *visibleViewController = [(UINavigationController *)viewController visibleViewController];
            if (visibleViewController && visibleViewController != viewController) {
                viewController = visibleViewController;
                continue;
            }
        }
        if ([viewController isKindOfClass:[UITabBarController class]]) {
            UIViewController *selectedViewController = [(UITabBarController *)viewController selectedViewController];
            if (selectedViewController && selectedViewController != viewController) {
                viewController = selectedViewController;
                continue;
            }
        }
        break;
    }
    return viewController;
}

+ (void)showNextAlertIfNeeded {
    if (MLeaksFinderIsDisabled()) {
        [pendingAlertContexts removeAllObjects];
        isPresentingAlert = NO;
        return;
    }
    
    if (isPresentingAlert || !pendingAlertContexts.count) {
        return;
    }
    
    isPresentingAlert = YES;
    MLeaksMessengerAlertContext *context = pendingAlertContexts.firstObject;
    [pendingAlertContexts removeObjectAtIndex:0];
    
    UIAlertController *alertControllerTemp = [UIAlertController alertControllerWithTitle:context.title
                                                                                 message:context.message
                                                                          preferredStyle:UIAlertControllerStyleAlert];
    void (^completeCurrentAlert)(void) = ^{
        isPresentingAlert = NO;
        [MLeaksMessenger showNextAlertIfNeeded];
    };
    [alertControllerTemp addAction:[UIAlertAction actionWithTitle:@"OK"
                                                            style:UIAlertActionStyleCancel
                                                          handler:^(UIAlertAction *) {
                                                              completeCurrentAlert();
                                                          }]];
    if (context.additionalButtonTitle.length && context.actionHandler) {
        [alertControllerTemp addAction:[UIAlertAction actionWithTitle:context.additionalButtonTitle
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction *) {
                                                                  context.actionHandler();
                                                                  completeCurrentAlert();
                                                              }]];
    }
    
    UIViewController *viewController = [self topViewController];
    if (viewController) {
        // 泄漏提示可能连续触发，这里串行展示，避免同一个 presenter 连续 present/dismiss。
        [viewController presentViewController:alertControllerTemp animated:YES completion:nil];
    } else {
        completeCurrentAlert();
    }
    
    NSLog(@"%@: %@", context.title, context.message);
}

+ (void)alertWithTitle:(NSString *)title message:(NSString *)message {
    [self alertWithTitle:title message:message additionalButtonTitle:nil actionHandler:nil];
}

+ (void)alertWithTitle:(NSString *)title
               message:(NSString *)message
 additionalButtonTitle:(NSString *)additionalButtonTitle
         actionHandler:(MLeaksMessengerActionHandler)actionHandler {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (MLeaksFinderIsDisabled()) {
            return;
        }
        if (!pendingAlertContexts) {
            pendingAlertContexts = [NSMutableArray array];
        }
        MLeaksMessengerAlertContext *context = [[MLeaksMessengerAlertContext alloc] init];
        context.title = title;
        context.message = message;
        context.additionalButtonTitle = additionalButtonTitle;
        context.actionHandler = actionHandler;
        [pendingAlertContexts addObject:context];
        [self showNextAlertIfNeeded];
    });
}

@end
