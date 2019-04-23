//
//  DSXRLibrary+Opcode.h
//  xref
//
//  Created by Derek Selander on 4/21/19.
//  Copyright © 2019 Selander. All rights reserved.
//

#import "DSXRLibrary.h"

NS_ASSUME_NONNULL_BEGIN

@interface DSXRLibrary (Opcode)

- (void)parseOpcodes:(int)fd;
- (void)addToDictionaries:(uintptr_t)address symbol:(char *)symbol;
@end

NS_ASSUME_NONNULL_END
