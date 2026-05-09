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

#import "NSObject+MemoryLeak.h"
#import "MLeakedObjectProxy.h"
#import "MLeaksFinder.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#if _INTERNAL_MLF_RC_ENABLED
#import "FBRetainCycleDetector/Detector/FBRetainCycleDetector.h"
#endif

static const void *const kViewStackKey = &kViewStackKey;
static const void *const kParentPtrsKey = &kParentPtrsKey;
const void *const kLatestSenderKey = &kLatestSenderKey;

static NSString * const kMLeaksFinderDisabledKey = @"MLeaksFinderDisabledKey";

// 一次检测延迟（秒）：UIKit/UINavigationController 触发 willDealloc 后的初次复查窗口。
static const NSTimeInterval kMLFFirstCheckDelay = 2.0;
// 二次检测延迟（秒）：用于过滤“延迟释放”类的误报（键盘消失动画、cell prefetch、网络回调、
// CADisplayLink、UIKit 内部 retainAutoreleased 等）。在 2026 年的 iOS 上，
// 仅 2s 阈值会产生大量"Memory Leak → Object Deallocated"配对噪音；二次检测命中率高且代价小。
// 阈值取舍：与首次窗口合计 5s（2 + 3），覆盖键盘/动画/cell prefetch 类延迟；
// 真泄漏永远不释放，仍会被报出，仅推迟告警时机而不影响识别能力。
static const NSTimeInterval kMLFSecondCheckDelay = 3.0;

BOOL MLeaksFinderIsDisabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kMLeaksFinderDisabledKey];
}

@implementation NSObject (MemoryLeak)

- (BOOL)willDealloc {
    if (MLeaksFinderIsDisabled()) {
        return NO;
    }
    
    NSString *className = NSStringFromClass([self class]);
    if ([[NSObject classNamesWhitelist] containsObject:className])
        return NO;

    NSNumber *senderPtr = objc_getAssociatedObject([UIApplication sharedApplication], kLatestSenderKey);
    if ([senderPtr isEqualToNumber:@((uintptr_t)self)])
        return NO;

    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMLFFirstCheckDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (MLeaksFinderIsDisabled()) {
            return;
        }
        __strong id strongSelf = weakSelf;
        [strongSelf assertNotDealloc];
    });

    return YES;
}

- (void)assertNotDealloc {
    if (MLeaksFinderIsDisabled()) {
        return;
    }
    
    if ([MLeakedObjectProxy isAnyObjectLeakedAtPtrs:[self parentPtrs]]) {
        return;
    }

    // 二次确认：首次检测命中后再延迟一段时间复查，自然释放则静默丢弃，避免“延迟释放”误报。
    // 仅真正在二次窗口结束时仍存活的对象才进入告警链路。
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMLFSecondCheckDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (MLeaksFinderIsDisabled()) {
            return;
        }
        __strong id strongSelf = weakSelf;
        if (!strongSelf) {
            return; // 已自然释放，确认非泄漏
        }
        // 二次窗口期间，可能由其它检测路径已加入泄漏集合（同一 view 树触发多次），需再次去重。
        if ([MLeakedObjectProxy isAnyObjectLeakedAtPtrs:[strongSelf parentPtrs]]) {
            return;
        }
        [MLeakedObjectProxy addLeakedObject:strongSelf];

        NSString *className = NSStringFromClass([strongSelf class]);
        NSLog(@"Possibly Memory Leak.\nIn case that %@ should not be dealloced, override -willDealloc in %@ by returning NO.\nView-ViewController stack: %@", className, className, [strongSelf viewStack]);
    });
}

- (void)willReleaseObject:(id)object relationship:(NSString *)relationship {
    if ([relationship hasPrefix:@"self"]) {
        relationship = [relationship stringByReplacingCharactersInRange:NSMakeRange(0, 4) withString:@""];
    }
    NSString *className = NSStringFromClass([object class]);
    className = [NSString stringWithFormat:@"%@(%@), ", relationship, className];
    
    [object setViewStack:[[self viewStack] arrayByAddingObject:className]];
    [object setParentPtrs:[[self parentPtrs] setByAddingObject:@((uintptr_t)object)]];
    [object willDealloc];
}

- (void)willReleaseChild:(id)child {
    if (!child) {
        return;
    }
    
    [self willReleaseChildren:@[ child ]];
}

- (void)willReleaseChildren:(NSArray *)children {
    NSArray *viewStack = [self viewStack];
    NSSet *parentPtrs = [self parentPtrs];
    for (id child in children) {
        NSString *className = NSStringFromClass([child class]);
        [child setViewStack:[viewStack arrayByAddingObject:className]];
        [child setParentPtrs:[parentPtrs setByAddingObject:@((uintptr_t)child)]];
        [child willDealloc];
    }
}

- (NSArray *)viewStack {
    NSArray *viewStack = objc_getAssociatedObject(self, kViewStackKey);
    if (viewStack) {
        return viewStack;
    }
    
    NSString *className = NSStringFromClass([self class]);
    return @[ className ];
}

- (void)setViewStack:(NSArray *)viewStack {
    objc_setAssociatedObject(self, kViewStackKey, viewStack, OBJC_ASSOCIATION_RETAIN);
}

- (NSSet *)parentPtrs {
    NSSet *parentPtrs = objc_getAssociatedObject(self, kParentPtrsKey);
    if (!parentPtrs) {
        parentPtrs = [[NSSet alloc] initWithObjects:@((uintptr_t)self), nil];
    }
    return parentPtrs;
}

- (void)setParentPtrs:(NSSet *)parentPtrs {
    objc_setAssociatedObject(self, kParentPtrsKey, parentPtrs, OBJC_ASSOCIATION_RETAIN);
}

+ (NSMutableSet *)classNamesWhitelist {
    static NSMutableSet *whitelist = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        whitelist = [NSMutableSet setWithObjects:
                     @"UIFieldEditor", // UIAlertControllerTextField
                     @"UINavigationBar",
                     @"_UIAlertControllerActionView",
                     @"_UIVisualEffectBackdropView",
                     nil];
        
        // System's bug since iOS 10 and not fixed yet up to this ci.
        NSString *systemVersion = [UIDevice currentDevice].systemVersion;
        if ([systemVersion compare:@"10.0" options:NSNumericSearch] != NSOrderedAscending) {
            [whitelist addObject:@"UISwitch"];
        }
    });
    return whitelist;
}

+ (void)addClassNamesToWhitelist:(NSArray *)classNames {
    [[self classNamesWhitelist] addObjectsFromArray:classNames];
}

+ (void)swizzleSEL:(SEL)originalSEL withSEL:(SEL)swizzledSEL {
#if _INTERNAL_MLF_ENABLED
    
#if _INTERNAL_MLF_RC_ENABLED
    // Just find a place to set up FBRetainCycleDetector.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [FBAssociationManager hook];
        });
    });
#endif
    
    Class class = [self class];
    
    Method originalMethod = class_getInstanceMethod(class, originalSEL);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSEL);
    
    BOOL didAddMethod =
    class_addMethod(class,
                    originalSEL,
                    method_getImplementation(swizzledMethod),
                    method_getTypeEncoding(swizzledMethod));
    
    if (didAddMethod) {
        class_replaceMethod(class,
                            swizzledSEL,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
#endif
}

@end
