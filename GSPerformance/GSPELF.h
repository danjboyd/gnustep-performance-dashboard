/* GSPELF.h - the ELF definitions the symbolicator needs.  Traces recorded
   on Linux can be opened on any platform, including ones without <elf.h>
   (MinGW), so the few structures used are defined here when needed.  */

#ifndef GSP_ELF_H
#define GSP_ELF_H

#if defined(__has_include)
#  if __has_include(<elf.h>)
#    include <elf.h>
#    define GSP_HAVE_SYSTEM_ELF 1
#  endif
#endif

#ifndef GSP_HAVE_SYSTEM_ELF
#include <stdint.h>

#define EI_NIDENT 16
#define EI_CLASS 4
#define ELFCLASS64 2
#define ELFMAG "\177ELF"
#define SELFMAG 4
#define SHT_PROGBITS 1
#define SHT_SYMTAB 2
#define SHT_NOTE 7
#define SHT_DYNSYM 11
#define SHN_UNDEF 0
#define STT_FUNC 2
#define STT_GNU_IFUNC 10
#define NT_GNU_BUILD_ID 3
#define ELF64_ST_TYPE(i) ((i) & 0xf)

typedef struct
{
  unsigned char e_ident[EI_NIDENT];
  uint16_t e_type, e_machine;
  uint32_t e_version;
  uint64_t e_entry, e_phoff, e_shoff;
  uint32_t e_flags;
  uint16_t e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
} Elf64_Ehdr;

typedef struct
{
  uint32_t sh_name, sh_type;
  uint64_t sh_flags, sh_addr, sh_offset, sh_size;
  uint32_t sh_link, sh_info;
  uint64_t sh_addralign, sh_entsize;
} Elf64_Shdr;

typedef struct
{
  uint32_t st_name;
  unsigned char st_info, st_other;
  uint16_t st_shndx;
  uint64_t st_value, st_size;
} Elf64_Sym;
#endif

#endif
