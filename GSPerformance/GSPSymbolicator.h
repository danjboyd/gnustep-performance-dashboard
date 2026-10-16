/* GSPSymbolicator.h - turning addresses into function names.

   Sources, best first:
   1. a symbols-<pid>.plist cache stored in the trace bundle (written by
      `gstrace symbolicate`, so traces can be read on other machines);
   2. the Objective-C method table the agent dumps at the end of a
      recording (GNUstep's libraries are normally stripped);
   3. ELF .symtab/.dynsym of the image, or of its separate debug file found
      by build-id or .gnu_debuglink under /usr/lib/debug.  */

#import <Foundation/Foundation.h>

@class GSPProcess;

@interface GSPSymbol : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *imagePath;
@property (nonatomic) uint64_t address;     /* the frame address */
@property (nonatomic) uint64_t start;       /* function start, 0 if unknown */
@property (nonatomic) BOOL isSystem;        /* in a system library */
@property (nonatomic) BOOL isUnknown;       /* no symbol found */
@property (nonatomic, readonly) NSString *imageName;
@property (nonatomic, readonly) NSString *key;  /* name + image, for merging */
@end

@interface GSPSymbolicator : NSObject

- (instancetype) initWithProcess: (GSPProcess *)process;

/* `index` is the frame's position in its stack: return addresses (index
   > 0) are looked up at address - 1.  */
- (GSPSymbol *) symbolForFrame: (uint64_t)address index: (NSUInteger)index;
- (GSPSymbol *) symbolForAddress: (uint64_t)address;

/* The symbols of a stack, leaf first, as views should show them: the
   recording agent's own frames are removed (a leading run is the agent at
   work; frames further down are its transparent interposers).  Returns an
   empty array for an empty stack and nil when only agent frames remain
   (time spent recording).  Cached. */
- (NSArray *) symbolsForStack: (uint32_t)stack;
/* Like -symbolsForStack: but the frame addresses (NSNumber), aligned with
   it and already adjusted to point at the call (use index 0 with them). */
- (NSArray *) addressesForStack: (uint32_t)stack;

/* "file.m:42" via addr2line (llvm-addr2line on Windows), or nil.  Slow;
   cached. */
- (NSString *) sourceLocationForFrame: (uint64_t)address index: (NSUInteger)index;

/* Forget caches after the process' images or methods changed. */
- (void) invalidate;

/* Address -> name for every frame of every stack, for embedding in the
   trace bundle. */
- (NSDictionary *) symbolTableForAllStacks;

+ (BOOL) isSystemLibraryPath: (NSString *)path;
+ (NSString *) addr2linePath;   /* nil when no addr2line is installed */
+ (NSString *) prettyObjCName: (NSString *)elfName;
+ (NSString *) demangle: (NSString *)name;

@end
