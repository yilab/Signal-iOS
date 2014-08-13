//
//  DebugLogger.h
//  Signal
//
//  Created by Frederic Jacobs on 08/08/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface DebugLogger : NSObject

MacrosSingletonInterface

- (void)enableFileLogging;

- (void)disableFileLogging;

- (void)enableTTYLogging;

- (void)wipeLogs;

@end