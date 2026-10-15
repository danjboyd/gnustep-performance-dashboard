#import "GSPSymbolicator.h"
#import "GSPTrace.h"
#import "GSPStackTable.h"

#include <dlfcn.h>
#include <elf.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* ELF symbol tables                                                   */

typedef struct elf_sym
{
  uint64_t start;
  uint64_t size;
  uint32_t name;    /* offset into the names blob */
  uint32_t pad;
} elf_sym;

@interface GSPELFFile : NSObject
{
@public
  elf_sym *syms;
  NSUInteger count;
  NSMutableData *names;
  BOOL hasSymtab;
  NSData *buildID;
  NSString *debugLink;
}
+ (GSPELFFile *) fileAtPath: (NSString *)path;
- (const elf_sym *) symbolFor: (uint64_t)vaddr;
- (NSString *) nameOf: (const elf_sym *)s;
@end

static int
compare_elf_syms(const void *a, const void *b)
{
  const elf_sym *x = a, *y = b;
  if (x->start != y->start)
    return x->start < y->start ? -1 : 1;
  /* prefer sized symbols at the same address */
  return (x->size < y->size) - (x->size > y->size);
}

@implementation GSPELFFile

- (void) dealloc
{
  free(syms);
}

static NSMutableDictionary *elfCache;

- (BOOL) loadData: (NSData *)data
{
  const uint8_t *b = [data bytes];
  NSUInteger len = [data length];
  const Elf64_Ehdr *eh = (const Elf64_Ehdr *)b;
  const Elf64_Shdr *sh;
  NSUInteger cap = 0;

  if (len < sizeof(Elf64_Ehdr) || memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0
      || eh->e_ident[EI_CLASS] != ELFCLASS64 || eh->e_shoff == 0
      || eh->e_shoff + (uint64_t)eh->e_shnum * sizeof(Elf64_Shdr) > len)
    return NO;
  sh = (const Elf64_Shdr *)(b + eh->e_shoff);
  names = [NSMutableData data];

  /* build-id and debuglink */
  const Elf64_Shdr *shstr = eh->e_shstrndx < eh->e_shnum ? &sh[eh->e_shstrndx] : NULL;
  for (int i = 0; i < eh->e_shnum; i++)
    {
      if (sh[i].sh_offset + sh[i].sh_size > len)
        continue;
      if (sh[i].sh_type == SHT_NOTE)
        {
          const uint8_t *n = b + sh[i].sh_offset, *end = n + sh[i].sh_size;
          while (n + 12 <= end)
            {
              uint32_t namesz = *(const uint32_t *)n;
              uint32_t descsz = *(const uint32_t *)(n + 4);
              uint32_t type = *(const uint32_t *)(n + 8);
              const uint8_t *nm = n + 12;
              const uint8_t *desc = nm + ((namesz + 3) & ~3u);
              if (desc + descsz > end)
                break;
              if (type == NT_GNU_BUILD_ID && namesz == 4 && memcmp(nm, "GNU", 4) == 0)
                buildID = [NSData dataWithBytes: desc length: descsz];
              n = desc + ((descsz + 3) & ~3u);
            }
        }
      if (shstr && sh[i].sh_type == SHT_PROGBITS
          && shstr->sh_offset + sh[i].sh_name < len
          && strcmp((const char *)b + shstr->sh_offset + sh[i].sh_name,
                    ".gnu_debuglink") == 0)
        debugLink = [NSString stringWithUTF8String:
          (const char *)b + sh[i].sh_offset];
    }

  for (int pass = 0; pass < 2; pass++)
    {
      uint32_t want = pass == 0 ? SHT_SYMTAB : SHT_DYNSYM;
      for (int i = 0; i < eh->e_shnum; i++)
        {
          if (sh[i].sh_type != want || sh[i].sh_link >= eh->e_shnum)
            continue;
          const Elf64_Shdr *strsh = &sh[sh[i].sh_link];
          if (sh[i].sh_offset + sh[i].sh_size > len
              || strsh->sh_offset + strsh->sh_size > len)
            continue;
          const Elf64_Sym *s = (const Elf64_Sym *)(b + sh[i].sh_offset);
          NSUInteger n = sh[i].sh_size / sizeof(Elf64_Sym);
          const char *strtab = (const char *)b + strsh->sh_offset;
          for (NSUInteger k = 0; k < n; k++)
            {
              int type = ELF64_ST_TYPE(s[k].st_info);
              if ((type != STT_FUNC && type != STT_GNU_IFUNC)
                  || s[k].st_shndx == SHN_UNDEF || s[k].st_value == 0
                  || s[k].st_name >= strsh->sh_size)
                continue;
              if (count == cap)
                {
                  cap = cap ? cap * 2 : 1024;
                  syms = realloc(syms, cap * sizeof(elf_sym));
                }
              const char *nm = strtab + s[k].st_name;
              syms[count].start = s[k].st_value;
              syms[count].size = s[k].st_size;
              syms[count].name = (uint32_t)[names length];
              syms[count].pad = 0;
              [names appendBytes: nm length: strlen(nm) + 1];
              count++;
            }
          if (want == SHT_SYMTAB && count > 0)
            hasSymtab = YES;
        }
      if (hasSymtab)
        break;   /* .symtab is a superset of .dynsym */
    }
  if (count > 1)
    qsort(syms, count, sizeof(elf_sym), compare_elf_syms);
  return YES;
}

static NSString *
hex_string(NSData *d)
{
  NSMutableString *s = [NSMutableString string];
  const uint8_t *b = [d bytes];
  for (NSUInteger i = 0; i < [d length]; i++)
    [s appendFormat: @"%02x", b[i]];
  return s;
}

- (void) loadDebugFileFor: (NSString *)path
{
  NSMutableArray *candidates = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];

  if ([buildID length] > 1)
    {
      NSString *hex = hex_string(buildID);
      [candidates addObject: [NSString stringWithFormat:
        @"/usr/lib/debug/.build-id/%@/%@.debug",
        [hex substringToIndex: 2], [hex substringFromIndex: 2]]];
    }
  if (debugLink != nil)
    {
      NSString *dir = [path stringByDeletingLastPathComponent];
      [candidates addObject: [dir stringByAppendingPathComponent: debugLink]];
      [candidates addObject: [[dir stringByAppendingPathComponent: @".debug"]
                               stringByAppendingPathComponent: debugLink]];
      [candidates addObject: [[@"/usr/lib/debug" stringByAppendingPathComponent: dir]
                               stringByAppendingPathComponent: debugLink]];
    }
  for (NSString *c in candidates)
    {
      if (![fm fileExistsAtPath: c] || [c isEqual: path])
        continue;
      GSPELFFile *dbg = [GSPELFFile new];
      NSData *d = [NSData dataWithContentsOfFile: c];
      if (d != nil && [dbg loadData: d] && dbg->count > count)
        {
          free(syms);
          syms = dbg->syms;
          dbg->syms = NULL;
          count = dbg->count;
          names = dbg->names;
          hasSymtab = YES;
          return;
        }
    }
}

+ (GSPELFFile *) fileAtPath: (NSString *)path
{
  GSPELFFile *f;

  @synchronized (self)
    {
      if (elfCache == nil)
        elfCache = [NSMutableDictionary dictionary];
      f = [elfCache objectForKey: path];
      if (f != nil)
        return [f isKindOfClass: [GSPELFFile class]] ? f : nil;
      /* Pseudo images (linux-vdso.so.1) have no file; GNUstep's mapped
         NSData does not cope with missing files.  */
      NSData *d = nil;
      BOOL isDir = NO;
      if ([path isAbsolutePath]
          && [[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isDir]
          && !isDir)
        d = [NSData dataWithContentsOfMappedFile: path];
      f = [GSPELFFile new];
      if (d == nil || ![f loadData: d])
        {
          [elfCache setObject: [NSNull null] forKey: path];
          return nil;
        }
      if (!f->hasSymtab)
        [f loadDebugFileFor: path];
      [elfCache setObject: f forKey: path];
      return f;
    }
}

- (const elf_sym *) symbolFor: (uint64_t)vaddr
{
  NSUInteger lo = 0, hi = count;
  if (count == 0 || vaddr < syms[0].start)
    return NULL;
  while (hi - lo > 1)
    {
      NSUInteger mid = (lo + hi) / 2;
      if (syms[mid].start <= vaddr)
        lo = mid;
      else
        hi = mid;
    }
  /* walk back over zero-sized or non-covering symbols at the same start */
  const elf_sym *s = &syms[lo];
  if (s->size != 0 && vaddr >= s->start + s->size)
    {
      /* maybe an enclosing earlier symbol covers it */
      for (NSUInteger k = lo; k > 0 && lo - k < 8; k--)
        {
          const elf_sym *e = &syms[k - 1];
          if (e->size && vaddr < e->start + e->size)
            return e;
        }
      return NULL;
    }
  return s;
}

- (NSString *) nameOf: (const elf_sym *)s
{
  return [NSString stringWithUTF8String: (const char *)[names bytes] + s->name];
}

@end

/* ------------------------------------------------------------------ */

@implementation GSPSymbol

- (NSString *) imageName
{
  return [_imagePath lastPathComponent];
}

- (NSString *) key
{
  return [NSString stringWithFormat: @"%@\t%@", _name, [self imageName] ?: @""];
}

@end

@implementation GSPSymbolicator
{
  __weak GSPProcess *_process;
  NSMutableDictionary *_cache;     /* NSNumber -> GSPSymbol */
  NSMutableDictionary *_lines;
  uint64_t *_imps;
  NSUInteger _impCount;
  NSArray *_impNames;
  NSDictionary *_embedded;         /* NSString hex -> name */
  NSMutableDictionary *_stackSymbols;   /* NSNumber stack -> NSArray or NSNull */
  NSMutableDictionary *_stackAddresses;
  NSUInteger _methodCountSeen;
}

static char *(*cxa_demangle)(const char *, char *, size_t *, int *);

+ (void) initialize
{
  cxa_demangle = dlsym(RTLD_DEFAULT, "__cxa_demangle");
  if (cxa_demangle == NULL)
    {
      void *h = dlopen("libstdc++.so.6", RTLD_NOW | RTLD_LOCAL);
      if (h)
        cxa_demangle = dlsym(h, "__cxa_demangle");
    }
}

- (instancetype) initWithProcess: (GSPProcess *)process
{
  if ((self = [super init]) != nil)
    {
      _process = process;
      _cache = [NSMutableDictionary dictionary];
      _lines = [NSMutableDictionary dictionary];
      NSString *dir = [process.streamPath stringByDeletingLastPathComponent];
      NSString *embedded = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat: @"symbols-%d.plist", process.pid]];
      _embedded = [NSDictionary dictionaryWithContentsOfFile: embedded];
    }
  return self;
}

- (void) dealloc
{
  free(_imps);
}

- (void) invalidate
{
  [_cache removeAllObjects];
  [_stackSymbols removeAllObjects];
  [_stackAddresses removeAllObjects];
  free(_imps);
  _imps = NULL;
  _impCount = 0;
  _impNames = nil;
}

- (void) buildMethodIndex
{
  NSDictionary *methods = _process.methodNames;
  NSArray *keys = [[methods allKeys] sortedArrayUsingSelector: @selector(compare:)];
  NSMutableArray *names = [NSMutableArray arrayWithCapacity: [keys count]];

  free(_imps);
  _impCount = [keys count];
  _imps = malloc((_impCount + 1) * sizeof(uint64_t));
  for (NSUInteger i = 0; i < _impCount; i++)
    {
      NSNumber *k = [keys objectAtIndex: i];
      _imps[i] = [k unsignedLongLongValue];
      [names addObject: [methods objectForKey: k]];
    }
  _impNames = names;
  _methodCountSeen = [methods count];
}

- (GSPImage *) imageFor: (uint64_t)address
{
  NSArray *images = _process.images;
  NSUInteger lo = 0, hi = [images count];
  while (lo < hi)
    {
      NSUInteger mid = (lo + hi) / 2;
      GSPImage *im = [images objectAtIndex: mid];
      if (address < im.start)
        hi = mid;
      else if (address >= im.end)
        lo = mid + 1;
      else
        return im;
    }
  return nil;
}

+ (BOOL) isSystemLibraryPath: (NSString *)path
{
  static NSArray *prefixes;
  if (prefixes == nil)
    prefixes = [NSArray arrayWithObjects: @"/lib/", @"/lib64/", @"/usr/lib/",
                 @"/usr/lib64/", @"/usr/libexec/", @"/usr/GNUstep/",
                 @"/usr/local/lib/", @"/usr/local/GNUstep/", @"linux-vdso",
                 @"[vdso]", @"/clang64/", @"/mingw64/", nil];
  if ([path length] == 0)
    return NO;
  for (NSString *p in prefixes)
    if ([path hasPrefix: p])
      return YES;
  NSString *name = [path lastPathComponent];
  return [name hasPrefix: @"libgnustep-"] || [name hasPrefix: @"libobjc"]
    || [name hasPrefix: @"libgsperf"];
}

+ (NSString *) prettyObjCName: (NSString *)elfName
{
  /* gnustep-2 ABI: _i_Class_Category_sel_with_ / _c_Class__sel */
  BOOL instance = [elfName hasPrefix: @"_i_"];
  if (!instance && ![elfName hasPrefix: @"_c_"])
    return nil;
  NSString *rest = [elfName substringFromIndex: 3];
  NSRange r1 = [rest rangeOfString: @"_"];
  if (r1.location == NSNotFound || r1.location == 0)
    return nil;
  NSString *cls = [rest substringToIndex: r1.location];
  NSString *after = [rest substringFromIndex: NSMaxRange(r1)];
  NSRange r2 = [after rangeOfString: @"_"];
  if (r2.location == NSNotFound)
    return nil;
  NSString *cat = [after substringToIndex: r2.location];
  NSString *sel = [[after substringFromIndex: NSMaxRange(r2)]
                    stringByReplacingOccurrencesOfString: @"_" withString: @":"];
  if ([sel length] == 0)
    return nil;
  if ([cat length])
    cls = [NSString stringWithFormat: @"%@(%@)", cls, cat];
  return [NSString stringWithFormat: @"%c[%@ %@]", instance ? '-' : '+', cls, sel];
}

+ (NSString *) demangle: (NSString *)name
{
  if ([name hasPrefix: @"_Z"] && cxa_demangle != NULL)
    {
      int status = 0;
      char *out = cxa_demangle([name UTF8String], NULL, NULL, &status);
      if (out != NULL && status == 0)
        {
          NSString *s = [NSString stringWithUTF8String: out];
          free(out);
          return s;
        }
      free(out);
    }
  NSString *objc = [self prettyObjCName: name];
  return objc ? objc : name;
}

- (GSPSymbol *) symbolForAddress: (uint64_t)address
{
  NSNumber *key = [NSNumber numberWithUnsignedLongLong: address];
  GSPSymbol *sym = [_cache objectForKey: key];
  if (sym != nil)
    return sym;

  sym = [GSPSymbol new];
  sym.address = address;
  GSPImage *image = [self imageFor: address];
  sym.imagePath = image.path;
  sym.isSystem = image ? [GSPSymbolicator isSystemLibraryPath: image.path] : NO;

  NSString *name = nil;
  uint64_t start = 0;

  if (_embedded != nil)
    name = [_embedded objectForKey: [NSString stringWithFormat: @"%llx",
                                     (unsigned long long)address]];

  if (name == nil)
    {
      const elf_sym *es = NULL;
      GSPELFFile *elf = nil;
      if (image != nil)
        {
          elf = [GSPELFFile fileAtPath: image.path];
          es = [elf symbolFor: address - image.base];
          if (es)
            start = es->start + image.base;
        }
      if (_impNames == nil || [_process.methodNames count] != _methodCountSeen)
        [self buildMethodIndex];
      if (_impCount > 0 && address >= _imps[0])
        {
          NSUInteger lo = 0, hi = _impCount;
          while (hi - lo > 1)
            {
              NSUInteger mid = (lo + hi) / 2;
              if (_imps[mid] <= address)
                lo = mid;
              else
                hi = mid;
            }
          uint64_t imp = _imps[lo];
          BOOL sameImage = image == nil || (imp >= image.start && imp < image.end);
          if (sameImage && address - imp < (1u << 20)
              && (es == NULL || imp >= start))
            {
              name = [_impNames objectAtIndex: lo];
              start = imp;
            }
        }
      if (name == nil && es != NULL)
        name = [GSPSymbolicator demangle: [elf nameOf: es]];
    }

  if (name == nil)
    {
      sym.isUnknown = YES;
      if (image != nil)
        name = [NSString stringWithFormat: @"%@+0x%llx", image.name,
                         (unsigned long long)(address - image.base)];
      else
        name = [NSString stringWithFormat: @"0x%llx", (unsigned long long)address];
    }
  sym.name = name;
  sym.start = start;
  [_cache setObject: sym forKey: key];
  return sym;
}

static BOOL
is_agent(GSPSymbol *s)
{
  return [[s imageName] hasPrefix: @"libgsperf-agent"];
}

- (void) computeStack: (uint32_t)stack
{
  NSNumber *key = [NSNumber numberWithUnsignedInt: stack];
  NSUInteger n;
  const uint64_t *f = [_process.stacks framesForStack: stack count: &n];
  NSMutableArray *syms = [NSMutableArray arrayWithCapacity: n];
  NSMutableArray *addrs = [NSMutableArray arrayWithCapacity: n];
  NSUInteger i = 0;
  BOOL sawAgent = NO;

  if (_stackSymbols == nil)
    {
      _stackSymbols = [NSMutableDictionary dictionary];
      _stackAddresses = [NSMutableDictionary dictionary];
    }
  /* Leading run: a sample taken while the agent was working starts with a
     few libunwind/libc frames and then the agent itself.  Agent frames any
     deeper are interposers (objc_alloc_init...) inside real call paths.  */
  NSUInteger lead = 0;
  for (NSUInteger k = 0; k < n && k < 6; k++)
    if (is_agent([self symbolForFrame: f[k] index: k]))
      {
        lead = k + 1;
        sawAgent = YES;
        while (lead < n && is_agent([self symbolForFrame: f[lead] index: lead]))
          lead++;
        break;
      }
  for (i = sawAgent ? lead : 0; i < n; i++)
    {
      GSPSymbol *s = [self symbolForFrame: f[i] index: i];
      if (is_agent(s))
        continue;   /* interposer trampoline */
      [syms addObject: s];
      /* return addresses point after the call; report the call itself */
      [addrs addObject: [NSNumber numberWithUnsignedLongLong: i > 0 ? f[i] - 1 : f[i]]];
    }
  if (sawAgent && [syms count] == 0)
    {
      [_stackSymbols setObject: [NSNull null] forKey: key];
      [_stackAddresses setObject: [NSNull null] forKey: key];
      return;
    }
  [_stackSymbols setObject: syms forKey: key];
  [_stackAddresses setObject: addrs forKey: key];
}

- (NSArray *) symbolsForStack: (uint32_t)stack
{
  NSNumber *key = [NSNumber numberWithUnsignedInt: stack];
  id v = [_stackSymbols objectForKey: key];
  if (v == nil)
    {
      [self computeStack: stack];
      v = [_stackSymbols objectForKey: key];
    }
  return v == [NSNull null] ? nil : v;
}

- (NSArray *) addressesForStack: (uint32_t)stack
{
  NSNumber *key = [NSNumber numberWithUnsignedInt: stack];
  id v = [_stackAddresses objectForKey: key];
  if (v == nil)
    {
      [self computeStack: stack];
      v = [_stackAddresses objectForKey: key];
    }
  return v == [NSNull null] ? nil : v;
}

- (GSPSymbol *) symbolForFrame: (uint64_t)address index: (NSUInteger)index
{
  if (index > 0 && address > 0)
    address -= 1;
  return [self symbolForAddress: address];
}

- (NSString *) sourceLocationForFrame: (uint64_t)address index: (NSUInteger)index
{
  if (index > 0 && address > 0)
    address -= 1;
  NSNumber *key = [NSNumber numberWithUnsignedLongLong: address];
  id cached = [_lines objectForKey: key];
  if (cached != nil)
    return cached == [NSNull null] ? nil : cached;

  NSString *result = nil;
  GSPImage *image = [self imageFor: address];
  NSString *tool = @"/usr/bin/addr2line";
  if (image != nil && [[NSFileManager defaultManager] isExecutableFileAtPath: tool])
    {
      NSTask *task = [NSTask new];
      NSPipe *pipe = [NSPipe pipe];
      [task setLaunchPath: tool];
      [task setArguments: [NSArray arrayWithObjects: @"-e", image.path,
        [NSString stringWithFormat: @"0x%llx",
                  (unsigned long long)(address - image.base)], nil]];
      [task setStandardOutput: pipe];
      [task setStandardError: [NSFileHandle fileHandleWithNullDevice]];
      @try
        {
          [task launch];
          NSData *d = [[pipe fileHandleForReading] readDataToEndOfFile];
          [task waitUntilExit];
          NSString *s = [[NSString alloc] initWithData: d
                                              encoding: NSUTF8StringEncoding];
          s = [s stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
          NSRange disc = [s rangeOfString: @" (discriminator"];
          if (disc.location != NSNotFound)
            s = [s substringToIndex: disc.location];
          if ([s length] && ![s hasPrefix: @"??"])
            {
              NSArray *parts = [s componentsSeparatedByString: @":"];
              if ([parts count] >= 2 && ![[parts lastObject] isEqual: @"0"]
                  && ![[parts lastObject] isEqual: @"?"])
                result = [NSString stringWithFormat: @"%@:%@",
                  [[parts objectAtIndex: 0] lastPathComponent], [parts lastObject]];
            }
        }
      @catch (NSException *e)
        {
          result = nil;
        }
    }
  [_lines setObject: result ? (id)result : (id)[NSNull null] forKey: key];
  return result;
}

- (NSDictionary *) symbolTableForAllStacks
{
  NSMutableDictionary *table = [NSMutableDictionary dictionary];
  GSPStackTable *stacks = _process.stacks;
  for (uint32_t i = 1; i < [stacks count]; i++)
    {
      NSUInteger n;
      const uint64_t *f = [stacks framesForStack: i count: &n];
      for (NSUInteger k = 0; k < n; k++)
        {
          uint64_t a = k > 0 ? f[k] - 1 : f[k];
          NSString *hex = [NSString stringWithFormat: @"%llx", (unsigned long long)a];
          if ([table objectForKey: hex] != nil)
            continue;
          GSPSymbol *s = [self symbolForAddress: a];
          if (!s.isUnknown)
            [table setObject: s.name forKey: hex];
        }
    }
  return table;
}

@end
