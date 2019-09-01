//
//  XRMachOLibrary+ObjectiveC.m
//  xref
//
//  Created by Derek Selander on 4/29/19.
//  Copyright © 2019 Selander. All rights reserved.
//

// Knock out objc/runtime.h so I can use the actual headers
//#ifndef _OBJC_RUNTIME_H
//#define _OBJC_RUNTIME_H
//
////#import "objc-runtime-new.h"
//
//#endif // OBJC_RUNTIME


#import <libgen.h>
#import <stddef.h>

#import "XRMachOLibrary+ObjectiveC.h"
#import "XRMachOLibrary+SymbolDumper.h"
#import "objc_.h"
#import "XRMachOLibrary+Swift.h"
#import "XRSymbolEntry.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
    #import "swift/Demangling/Demangler.h"
    #import "XRMachOLibraryCplusHelpers.h"
#pragma clang diagnostic pop


/// Swift uses offset references for ivars when referencing methods
static NSMutableDictionary *__ivarsDictionary = nil;
/// Certain things -debugDescription that every class has, no need to display them
static NSDictionary <NSString*, NSNumber*> *blacklistedSelectors = nil;

@implementation XRMachOLibrary (ObjectiveC)

+ (void)load {
    blacklistedSelectors = @{
                             @".cxx_destruct" : @YES,
                             @"description" : @YES,
                             @"debugDescription" : @YES,
                             @"hash" : @YES
                             };
}

- (void)dumpObjCClassInfo:(const char *)name resolvedAddress:(swift_class*)cls {
    auto rodata = cls->disk()->rodata();
    if (rodata == nullptr) {
        return;
    }
    
    auto methodList = rodata->disk()->baseMethodList;
    if (methodList == nullptr) {
        return;
    }
    
    uint8_t isMeta = rodata->flags & RO_META ? 1 : 0 ;
    auto count = methodList->disk()->count;
    auto methods = &methodList->disk()->first_method;
    if (xref_options.verbose > VERBOSE_2) {
        printf("\t// %s methods\n", isMeta ? "class" : "instance");
    }
    
    for (int i = 0; i < count; i++) {
        auto method = methods[i];
        auto methodAddress = method.imp;
        auto methodName = method.name->disk();
        if (blacklistedSelectors[[NSString stringWithUTF8String:methodName]]) {
            continue;
        }
        printf("\t%s0x%011lx%s %s%c[%s %s]%s\n", dcolor(DSCOLOR_GRAY), (unsigned long)methodAddress, color_end(), dcolor(DSCOLOR_BOLD), "-+"[isMeta], name, methodName, color_end());
    }
}

/********************************************************************************
 // Properties
 ********************************************************************************/
- (void)dumpObjCPropertiesWithResolvedAddress:(swift_class*)cls {
  
    auto clsDisk = cls->disk();
    auto rodata = clsDisk->rodata();
    if (rodata == nullptr) {
        return;
    }
    
    auto propertiesList = rodata->disk()->baseProperties;
    if (propertiesList == nullptr) {
        return;
    }
    
    auto propertiesListDisk = propertiesList->disk();
    auto count = propertiesListDisk->count;
    auto properties = &propertiesListDisk->first_property;
    if (properties == nullptr) {
        return;
    }
    
    for (int i = 0; i < count; i++) {
        auto property = properties[i];
        auto propertyName = property.name->disk();
        auto propertyAttributes = property.attributes->disk();
        printf("\t%s@property %s%s %s%s%s\n", dcolor(DSCOLOR_GREEN), propertyAttributes, color_end(), dcolor(DSCOLOR_BOLD), propertyName, color_end());
    }
    
    if (count) {
        putchar('\n');
    }
}

/********************************************************************************
 // ivars
 ********************************************************************************/
- (void)dumpObjCInstanceVariablesWithResolvedAddress:(uintptr_t)resolvedAddress {

    auto cls = payload::LoadToDiskTranslator<swift_class>::Cast(resolvedAddress);
    if (cls == nullptr) {
        return;
    }
    
    auto clsDisk = cls->disk();
    auto rodata = clsDisk->rodata();
    if (rodata == nullptr) {
        return;
    }
    
    auto rodataDisk = rodata->disk();
    if (rodataDisk->ivarList == nullptr) {
        return;
    }
    
    auto ivarList = rodataDisk->ivarList;
    if (ivarList == nullptr) {
        return;
    }
    
    auto ivarListDisk = ivarList->disk();
    auto ivarCount = ivarListDisk->count;
    __ivarsDictionary = [NSMutableDictionary dictionaryWithCapacity:ivarCount];
    
    auto ivars = &ivarListDisk->first_ivar;

    printf("{\n");
    auto ivarsDisk = ivars->disk();
    
    for (int i = 0; i < ivarCount; i++) {
        auto ivr = &ivarsDisk[i];
        auto ivarOffsetPointer = ivr->offset;
        auto ivarOffset = ivarOffsetPointer ? *ivarOffsetPointer->disk() : 0;
        auto ivarName = ivr->name->disk();
        auto ivarType = xref_options.verbose > VERBOSE_2 ? ivr->type->disk() : "";
        __ivarsDictionary[@(ivarOffset)] = [NSString stringWithUTF8String:ivarName];
        printf("\t+0x%04x %s %s (0x%x)\n", ivarOffset, ivarType, ivarName, ivr->size);
    }
    
    printf("}\n");
}

/********************************************************************************
 // Objective-C class dump
 ********************************************************************************/
- (void)dumpObjectiveCClasses {
    // Defined symbols, will go after the __DATA.__objc_classlist pointers
    if (xref_options.defined || !(xref_options.undefined || xref_options.defined)) {
        
        struct section_64* classSection = payload::sectionsDict["__DATA.__objc_classlist"];
        if (classSection == nullptr) { // iOS 13 ARM64E has some changes...
            classSection = payload::sectionsDict["__DATA_CONST.__objc_classlist"];
        }
        if (classSection == nullptr) {
            return;
        }
        
        auto classes = payload::LoadToDiskTranslator<uintptr_t>::Cast(classSection->addr);
        char modname[1024];
        for (int i = 0; i < classSection->size / PTR_SIZE; i++) {
            
            auto resolvedAddress = classes->Get(i);
            auto cls = payload::Cast<swift_class*>(resolvedAddress);
            if (xref_options.swift_mode && !cls->isSwift()) {
                continue;
            }

            const char *name = cls->GetName();
            
            d_offsets off;
            if (xref_options.swift_mode) {
                std::string str;
                dshelpers::simple_demangle(name, str);
                printf("0x%011lx %s%s%s", resolvedAddress,  dcolor(DSCOLOR_CYAN), dshelpers::simple_demangle(name, str), color_end());
            } else {
                printf("0x%011lx %s%s%s", resolvedAddress,  dcolor(DSCOLOR_CYAN), name, color_end());
            }

            XRBindSymbol *objcReference = nil;
            char *color = dcolor(DSCOLOR_GREEN);
            
            ///////////////////////////////////////////////////
            // Print out the superclass if any verbose level //
            ///////////////////////////////////////////////////
            if (xref_options.verbose > VERBOSE_NONE) {
                // Check if it's a local symbol first via the dylds binding opcodes....
                auto superClassAddressDisk = &cls->disk()->superclass;
                auto superClassAddress = payload::GetLoadAddress(superClassAddressDisk);
                objcReference = self.addressObjCDictionary[@(superClassAddress)];
                const char *superclassName = objcReference.shortName.UTF8String;
                
                // Will happen if the superclass is implemented in the same module
                if (!superclassName) {
                    auto supercls = cls->disk()->superclass;
                    if (supercls) {
                        if (supercls->validAddress()) {
                            superclassName = supercls->disk()->GetName();
                            color = dcolor(DSCOLOR_MAGENTA);
                        } else {
                            //printf("\nproblem derek: %s\n", cls->GetName());
                        }
                    
                    }
                }
                color = superclassName ? color : dcolor(DSCOLOR_RED);
                std::string str;
                dshelpers::simple_demangle(superclassName, str);
                if (xref_options.swift_mode &&  demangleSwiftName(superclassName, &off)) {
                    printf(" : %s%s%s%s", color, modname, superclassName, color_end());
                } else {
                    auto rodata = cls->disk()->rodata();

                    if (!superclassName && (rodata->disk()->flags & RO_ROOT) == 0) {
                        printf(" %sbug! \"%s\" shouldn't be ROOT (report this to Derek) (0x%lu) %s", dcolor(DSCOLOR_RED), name,  resolvedAddress, color_end());
                    }
                    auto context = Context();
                    auto str = StringRef( superclassName);
                    printf(" : %s%s%s", color, superclassName ? context.demangleSymbolAsString(str).c_str() : "<ROOT>", color_end());
                }
            }
            
            //////////////////////////////////////////////////////
            // Print the libraries of Objc classes if verbose 4 //
            //////////////////////////////////////////////////////
            if (xref_options.verbose > VERBOSE_3) {
                char *libName = objcReference && objcReference.libOrdinal ? (char*)self.depdencies[objcReference.libOrdinal].UTF8String : NULL;
                if (libName) {
                    printf(" %s%s%s", dcolor(DSCOLOR_YELLOW), libName, color_end());
                }
            }
            
            ///////////////////////
            // Dump protocols... //
            ///////////////////////
            if (![self printObjectiveCProtocols:resolvedAddress]) {
                putchar('\n');
            }
            
            
            // property then method dumping logic dumbing logic
            if (xref_options.verbose > VERBOSE_2) {
                
                // Dump ivars...
                [self dumpObjCInstanceVariablesWithResolvedAddress:resolvedAddress];
                
                // Dump properties...
                [self dumpObjCPropertiesWithResolvedAddress:cls];
                
                // Dumps class methods first...
                auto metaCls = cls->disk()->isa();
                [self dumpObjCClassInfo:name resolvedAddress:metaCls];
                
                // Then Dump instance methods...
                [self dumpObjCClassInfo:name resolvedAddress:cls];
                
                putchar('\n');
            }
        }
    }
    
    // Undefined symbols, use the symbol table
    struct nlist_64 *symbols = self.symbols;
    if (xref_options.undefined || !(xref_options.undefined || xref_options.defined)) {
        for (int i = self.dysymtab->iundefsym; i < self.dysymtab->nundefsym + self.dysymtab->iundefsym; i++) {
            struct nlist_64 sym = symbols[i];
            char *chr = &self.str_symbols[sym.n_un.n_strx];
            
            if (!strnstr(chr, "_OBJC_CLASS_$_", OBJC_CLASS_LENGTH)) {
                continue;
            }

            print_symbol(self, &sym, NULL);
        }
    }
}

/********************************************************************************
 // Protocols
 ********************************************************************************/
-(BOOL)printObjectiveCProtocols:(uintptr_t)resolvedAddress {
    if (xref_options.verbose == VERBOSE_NONE) {
        return NO;
    }
    
    auto cls = payload::Cast<swift_class*>(resolvedAddress);
    if (cls == nullptr) {
        return NO;
    }
    
    auto rodata = cls->disk()->rodata();
    if (rodata == nullptr) {
        return NO;
    }
    
    auto protocolList = rodata->disk()->baseProtocols;
    if (protocolList == nullptr) {
        return NO;
    }
    
    auto count = protocolList->disk()->count;
    if (count == 0) {
        return NO;
    }
    
    auto protocols = &protocolList->disk()->first_protocol;
    printf("%s <", dcolor(DSCOLOR_YELLOW));
    
    for (int i = 0; i < count; i++) {
        auto prot = protocols[i];
        auto mangledName = prot->disk()->mangledName->disk();
        printf("%s", mangledName ? mangledName : "<unknown>");
        if (i != count - 1) {
            putchar(',');
            putchar(' ');
        }
    }
    printf(">\n%s", color_end());

    return YES;
}

@end



BOOL demangleSwiftName(const char *name, d_offsets *f) {
    
    if (!name || strlen(name) == 0) {
        f->success = NO;
        return NO;
    }
    if (!strstr(name, "_OBJC_CLASS_$__TtCs")) {
        f->success = NO;
        return NO;
    }
    
    int index = strlen("_TtC");
    f->mod_off = index;
    while (name[index] >= '0' && name[index] <= '9') {
        index++;
    }
    char md_len[5] = {};
    strncpy(md_len, &name[f->mod_off], index - f->mod_off);
    f->mod_len = atoi(md_len);
    
    index += f->mod_len ;
    while (name[index] >= '0' && name[index] <= '9') {
        index++;
    }
    f->cls_off = index;
    f->mod_off++;
    return YES;
}
