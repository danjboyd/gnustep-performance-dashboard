#import "GSPStackTable.h"

#include <stdlib.h>
#include <string.h>

typedef struct stack_entry
{
  uint64_t offset;   /* into frames */
  uint32_t count;
  uint32_t next;     /* hash chain, 0 = end */
  uint64_t hash;
} stack_entry;

@implementation GSPStackTable
{
  uint64_t *_frames;
  uint64_t _framesUsed, _framesCap;
  stack_entry *_entries;
  uint32_t _entryCount, _entryCap;
  uint32_t *_buckets;
  uint32_t _bucketMask;
}

- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _entryCap = 1024;
      _entries = calloc(_entryCap, sizeof(stack_entry));
      _entryCount = 1;              /* index 0: empty stack */
      _bucketMask = 4095;
      _buckets = calloc(_bucketMask + 1, sizeof(uint32_t));
      _framesCap = 8192;
      _frames = malloc(_framesCap * sizeof(uint64_t));
    }
  return self;
}

- (void) dealloc
{
  free(_frames);
  free(_entries);
  free(_buckets);
}

static uint64_t
hash_frames(const uint64_t *f, NSUInteger n)
{
  uint64_t h = 1469598103934665603ull ^ n;
  for (NSUInteger i = 0; i < n; i++)
    {
      h ^= f[i];
      h *= 1099511628211ull;
      h ^= h >> 29;
    }
  return h ? h : 1;
}

- (void) rehash
{
  uint32_t nmask = (_bucketMask + 1) * 2 - 1;
  uint32_t *nb = calloc(nmask + 1, sizeof(uint32_t));
  for (uint32_t i = 1; i < _entryCount; i++)
    {
      uint32_t b = (uint32_t)(_entries[i].hash & nmask);
      _entries[i].next = nb[b];
      nb[b] = i;
    }
  free(_buckets);
  _buckets = nb;
  _bucketMask = nmask;
}

- (uint32_t) internFrames: (const uint64_t *)frames count: (NSUInteger)count
{
  uint64_t h;
  uint32_t b, i;

  if (count == 0)
    return 0;
  h = hash_frames(frames, count);
  b = (uint32_t)(h & _bucketMask);
  for (i = _buckets[b]; i != 0; i = _entries[i].next)
    if (_entries[i].hash == h && _entries[i].count == count
        && memcmp(_frames + _entries[i].offset, frames, count * 8) == 0)
      return i;

  if (_entryCount == _entryCap)
    {
      _entryCap *= 2;
      _entries = realloc(_entries, _entryCap * sizeof(stack_entry));
    }
  while (_framesUsed + count > _framesCap)
    {
      _framesCap *= 2;
      _frames = realloc(_frames, _framesCap * sizeof(uint64_t));
    }
  memcpy(_frames + _framesUsed, frames, count * 8);
  i = _entryCount++;
  _entries[i].offset = _framesUsed;
  _entries[i].count = (uint32_t)count;
  _entries[i].hash = h;
  _entries[i].next = _buckets[b];
  _buckets[b] = i;
  _framesUsed += count;
  if (_entryCount > (_bucketMask + 1) * 2)
    [self rehash];
  return i;
}

- (const uint64_t *) framesForStack: (uint32_t)index count: (NSUInteger *)count
{
  if (index == 0 || index >= _entryCount)
    {
      *count = 0;
      return NULL;
    }
  *count = _entries[index].count;
  return _frames + _entries[index].offset;
}

- (NSUInteger) count
{
  return _entryCount;
}

- (NSSet *) allAddresses
{
  NSMutableSet *set = [NSMutableSet set];
  for (uint64_t i = 0; i < _framesUsed; i++)
    [set addObject: [NSNumber numberWithUnsignedLongLong: _frames[i]]];
  return set;
}

@end
