#import "GSPSymbolicator.h"
#import "GSPTrace.h"
#import "GSPStackTable.h"

#include "GSPELF.h"
#if defined(_WIN32)
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif
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
  uint64_t *funcStarts;      /* from .eh_frame_hdr, sorted */
  NSUInteger funcCount;
}
- (BOOL) functionStart: (uint64_t)vaddr into: (uint64_t *)start;
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
  free(funcStarts);
}

static NSMutableDictionary *elfCache;

static int
cmp_u64(const void *a, const void *b)
{
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return (x > y) - (x < y);
}

/* .eh_frame_hdr's binary search table lists the start of every function
   with unwind info, stripped or not.  Only the common encoding
   (DW_EH_PE_datarel | DW_EH_PE_sdata4) is handled.  */
- (void) loadFunctionStarts: (const uint8_t *)b length: (NSUInteger)len
                   sections: (const Elf64_Shdr *)sh count: (int)shnum
                   shstrtab: (const Elf64_Shdr *)shstr
{
  for (int i = 0; i < shnum && shstr; i++)
    {
      if (shstr->sh_offset + sh[i].sh_name >= len
          || strcmp((const char *)b + shstr->sh_offset + sh[i].sh_name, ".eh_frame_hdr") != 0
          || sh[i].sh_offset + sh[i].sh_size > len || sh[i].sh_size < 12)
        continue;
      const uint8_t *h = b + sh[i].sh_offset;
      uint8_t version = h[0], ptrEnc = h[1], countEnc = h[2], tableEnc = h[3];
      if (version != 1 || countEnc != 0x03 || tableEnc != 0x3b)
        return;
      size_t pos = 4;
      if ((ptrEnc & 0x0f) == 0x0b || (ptrEnc & 0x0f) == 0x03)
        pos += 4;
      else if ((ptrEnc & 0x0f) == 0x0c || (ptrEnc & 0x0f) == 0x04)
        pos += 8;
      else
        return;
      if (pos + 4 > sh[i].sh_size)
        return;
      uint32_t fdeCount;
      memcpy(&fdeCount, h + pos, 4);
      pos += 4;
      if (pos + (size_t)fdeCount * 8 > sh[i].sh_size)
        return;
      funcStarts = malloc((fdeCount + 1) * sizeof(uint64_t));
      for (uint32_t k = 0; k < fdeCount; k++)
        {
          int32_t rel;
          memcpy(&rel, h + pos + (size_t)k * 8, 4);
          funcStarts[funcCount++] = (uint64_t)((int64_t)sh[i].sh_addr + rel);
        }
      qsort(funcStarts, funcCount, sizeof(uint64_t), cmp_u64);
      return;
    }
}

- (BOOL) functionStart: (uint64_t)vaddr into: (uint64_t *)start
{
  if (funcCount == 0 || vaddr < funcStarts[0])
    return NO;
  NSUInteger lo = 0, hi = funcCount;
  while (hi - lo > 1)
    {
      NSUInteger mid = (lo + hi) / 2;
      if (funcStarts[mid] <= vaddr)
        lo = mid;
      else
        hi = mid;
    }
  *start = funcStarts[lo];
  return YES;
}

static uint16_t rd16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

- (void) addSymbol: (const char *)name length: (size_t)nlen start: (uint64_t)start
          capacity: (NSUInteger *)cap
{
  if (count == *cap)
    {
      *cap = *cap ? *cap * 2 : 1024;
      syms = realloc(syms, *cap * sizeof(elf_sym));
    }
  syms[count].start = start;
  syms[count].size = 0;
  syms[count].name = (uint32_t)[names length];
  syms[count].pad = 0;
  [names appendBytes: name length: nlen];
  [names appendBytes: "" length: 1];
  count++;
}

/* PE/COFF images (Windows): function names from the COFF symbol table
   (MinGW keeps it unless stripped) and the export table; function bounds
   from .pdata.  Addresses are RVAs, matching (address - module base).  */
- (BOOL) loadPE: (const uint8_t *)b length: (NSUInteger)len
{
  NSUInteger cap = 0;
  if (len < 0x40)
    return NO;
  uint32_t pe = rd32(b + 0x3c);
  if (pe + 24 > len || memcmp(b + pe, "PE\0\0", 4) != 0)
    return NO;
  const uint8_t *fh = b + pe + 4;
  uint16_t nsections = rd16(fh + 2);
  uint32_t symtab = rd32(fh + 8), nsyms = rd32(fh + 12);
  uint16_t optsize = rd16(fh + 16);
  const uint8_t *opt = fh + 20;
  if (opt + optsize > b + len || rd16(opt) != 0x20b)   /* PE32+ only */
    return NO;
  uint32_t ndirs = rd32(opt + 108);
  const uint8_t *dirs = opt + 112;
  const uint8_t *sec = opt + optsize;
  if (sec + nsections * 40 > b + len)
    return NO;
  names = [NSMutableData data];

  /* RVA -> file offset */
  uint32_t (^offset)(uint32_t) = ^uint32_t(uint32_t rva) {
    for (uint16_t i = 0; i < nsections; i++)
      {
        const uint8_t *s = sec + i * 40;
        uint32_t va = rd32(s + 12), vsize = rd32(s + 8), raw = rd32(s + 20), rsize = rd32(s + 16);
        if (rva >= va && rva < va + (vsize ? vsize : rsize))
          return raw + (rva - va);
      }
    return 0;
  };

  /* COFF symbol table */
  if (symtab && nsyms && symtab + (uint64_t)nsyms * 18 <= len)
    {
      const uint8_t *strtab = b + symtab + nsyms * 18;
      uint32_t strsize = (strtab + 4 <= b + len) ? rd32(strtab) : 0;
      for (uint32_t i = 0; i < nsyms; i++)
        {
          const uint8_t *e = b + symtab + i * 18;
          int16_t secnum = (int16_t)rd16(e + 12);
          uint16_t type = rd16(e + 14);
          uint8_t naux = e[17];
          if (secnum > 0 && secnum <= nsections && (type & 0x30) == 0x20)
            {
              const char *nm;
              size_t nl;
              char shortname[9];
              if (rd32(e) == 0)
                {
                  uint32_t o = rd32(e + 4);
                  if (o >= strsize || strtab + o >= b + len)
                    goto next;
                  nm = (const char *)strtab + o;
                  nl = strnlen(nm, (size_t)(b + len - (const uint8_t *)nm));
                }
              else
                {
                  memcpy(shortname, e, 8);
                  shortname[8] = 0;
                  nm = shortname;
                  nl = strlen(shortname);
                }
              uint32_t va = rd32(sec + (secnum - 1) * 40 + 12);
              [self addSymbol: nm length: nl start: va + rd32(e + 8) capacity: &cap];
            }
        next:
          i += naux;
        }
      if (count > 0)
        hasSymtab = YES;
    }

  /* exports */
  if (ndirs > 0)
    {
      uint32_t erva = rd32(dirs), esize = rd32(dirs + 4);
      uint32_t eoff = erva ? offset(erva) : 0;
      if (eoff && esize && eoff + 40 <= len)
        {
          uint32_t nnames = rd32(b + eoff + 24);
          uint32_t funcs = offset(rd32(b + eoff + 28));
          uint32_t namesp = offset(rd32(b + eoff + 32));
          uint32_t ords = offset(rd32(b + eoff + 36));
          for (uint32_t i = 0; funcs && namesp && ords && i < nnames; i++)
            {
              if (namesp + i * 4 + 4 > len || ords + i * 2 + 2 > len)
                break;
              uint32_t noff = offset(rd32(b + namesp + i * 4));
              uint16_t ord = rd16(b + ords + i * 2);
              if (noff == 0 || noff >= len || funcs + ord * 4 + 4 > len)
                continue;
              uint32_t frva = rd32(b + funcs + ord * 4);
              if (frva >= erva && frva < erva + esize)
                continue;   /* forwarder */
              const char *nm = (const char *)b + noff;
              [self addSymbol: nm length: strnlen(nm, len - noff) start: frva capacity: &cap];
            }
        }
    }

  /* .pdata: function starts */
  if (ndirs > 3)
    {
      uint32_t prva = rd32(dirs + 24), psize = rd32(dirs + 28);
      uint32_t poff = prva ? offset(prva) : 0;
      if (poff && psize && poff + psize <= len)
        {
          NSUInteger n = psize / 12;
          funcStarts = malloc((n + 1) * sizeof(uint64_t));
          for (NSUInteger i = 0; i < n; i++)
            funcStarts[funcCount++] = rd32(b + poff + i * 12);
          qsort(funcStarts, funcCount, sizeof(uint64_t), cmp_u64);
        }
    }
  if (count > 1)
    qsort(syms, count, sizeof(elf_sym), compare_elf_syms);
  return YES;
}

- (BOOL) loadData: (NSData *)data
{
  const uint8_t *b = [data bytes];
  NSUInteger len = [data length];
  if (len >= 2 && b[0] == 'M' && b[1] == 'Z')
    return [self loadPE: b length: len];
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
  [self loadFunctionStarts: b length: len sections: sh count: eh->e_shnum shstrtab: shstr];
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
#if defined(_WIN32)
  const char *runtimes[] = { "libc++.dll", "libstdc++-6.dll", NULL };
  for (int i = 0; runtimes[i] && cxa_demangle == NULL; i++)
    {
      HMODULE h = LoadLibraryA(runtimes[i]);
      if (h)
        cxa_demangle = (char *(*)(const char *, char *, size_t *, int *))
          GetProcAddress(h, "__cxa_demangle");
    }
#else
  cxa_demangle = dlsym(RTLD_DEFAULT, "__cxa_demangle");
  if (cxa_demangle == NULL)
    {
      void *h = dlopen("libstdc++.so.6", RTLD_NOW | RTLD_LOCAL);
      if (h)
        cxa_demangle = dlsym(h, "__cxa_demangle");
    }
#endif
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
  /* Windows: the system directory and MSYS2's runtime DLLs */
  NSString *lower = [path lowercaseString];
  if ([lower hasPrefix: @"c:/windows/"] || [lower rangeOfString: @"/clang64/bin/"].location != NSNotFound
      || [lower rangeOfString: @"/mingw64/bin/"].location != NSNotFound
      || [lower rangeOfString: @"/ucrt64/bin/"].location != NSNotFound)
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
      uint64_t fstart = 0;
      BOOL haveFunc = NO;
      if (image != nil)
        {
          elf = [GSPELFFile fileAtPath: image.path];
          es = [elf symbolFor: address - image.base];
          if (es)
            start = es->start + image.base;
          haveFunc = [elf functionStart: address - image.base into: &fstart];
        }
      if (_impNames == nil || [_process.methodNames count] != _methodCountSeen)
        [self buildMethodIndex];
      NSUInteger impIndex = NSNotFound;
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
          impIndex = lo;
        }
      if (haveFunc)
        {
          /* Exact function boundaries: a method or symbol name applies
             only if it starts this function.  */
          uint64_t fabs_ = fstart + image.base;
          if (impIndex != NSNotFound && _imps[impIndex] == fabs_)
            {
              name = [_impNames objectAtIndex: impIndex];
              start = fabs_;
            }
          else if (es != NULL && (es->start + image.base == fabs_
                                  || (es->size && address - image.base < es->start + es->size
                                      && es->start + image.base > fabs_)))
            name = [GSPSymbolicator demangle: [elf nameOf: es]];
          else if (es != NULL && es->size == 0 && es->start + image.base >= fabs_)
            name = [GSPSymbolicator demangle: [elf nameOf: es]];
          else
            {
              name = [NSString stringWithFormat: @"%@+0x%llx", image.name,
                               (unsigned long long)fstart];
              start = fabs_;
              sym.isUnknown = YES;
            }
        }
      else
        {
          if (impIndex != NSNotFound)
            {
              uint64_t imp = _imps[impIndex];
              BOOL sameImage = image == nil || (imp >= image.start && imp < image.end);
              if (sameImage && address - imp < (1u << 20)
                  && (es == NULL || imp >= start))
                {
                  name = [_impNames objectAtIndex: impIndex];
                  start = imp;
                }
            }
          if (name == nil && es != NULL)
            name = [GSPSymbolicator demangle: [elf nameOf: es]];
        }
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
  if ([name hasSuffix: @" [kernel]"])
    {
      sym.isSystem = YES;
      sym.imagePath = @"[kernel]";
    }
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
