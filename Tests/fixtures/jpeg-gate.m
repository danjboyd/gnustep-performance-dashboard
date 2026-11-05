/* Test-only live allocation/scan fixture.  The installed libs-gui may already
   have fixed #1010.  Inject a lost allocation into its actual JPEG probe while
   preserving the original image-decoding call, and keep an unrelated leak as
   a filtering control.  This is not an upstream-bug reproducer or app code. */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static BOOL (*original_probe)(id, SEL, NSData *);
static unsigned probe_calls;

__attribute__((noinline)) static BOOL
jpeg_gate_probe(id receiver, SEL selector, NSData *data)
{
  BOOL result = original_probe(receiver, selector, data);
  void *block = malloc(72);
  if (block == NULL)
    abort();
  memset(block, 0, 72);
  __asm__ volatile("" : : "r" (block) : "memory");
  probe_calls++;
  return result;
}

__attribute__((noinline)) static void
jpeg_gate_unrelated_leak(void)
{
  void *block = malloc(123);
  if (block == NULL)
    abort();
  memset(block, 0, 123);
  __asm__ volatile("" : : "r" (block) : "memory");
}

__attribute__((noinline)) static void
scrub_stack(void)
{
  volatile unsigned char bytes[32768];
  for (size_t i = 0; i < sizeof(bytes); i++)
    bytes[i] = 0;
}

int
main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
    initWithBitmapDataPlanes: NULL pixelsWide: 4 pixelsHigh: 4
    bitsPerSample: 8 samplesPerPixel: 3 hasAlpha: NO isPlanar: NO
    colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: 0 bitsPerPixel: 0];
  if (rep == nil)
    return 2;
  memset([rep bitmapData], 0, [rep bytesPerRow] * [rep pixelsHigh]);
  NSData *tiff = [rep TIFFRepresentation];
  NSData *png = [rep representationUsingType: NSPNGFileType
                               properties: [NSDictionary dictionary]];
  if (tiff == nil || png == nil)
    return 3;

  Method method = class_getClassMethod([NSBitmapImageRep class],
                                      sel_registerName("_bitmapIsJPEG:"));
  if (method == NULL)
    return 4;
  original_probe = (BOOL (*)(id, SEL, NSData *))
    method_setImplementation(method, (IMP)jpeg_gate_probe);
  if (original_probe == NULL)
    return 5;
  for (unsigned i = 0; i < 32; i++)
    {
      NSAutoreleasePool *inner = [NSAutoreleasePool new];
      if ([[NSBitmapImageRep imageRepsWithData: tiff] count] == 0
          || [[NSBitmapImageRep imageRepsWithData: png] count] == 0)
        return 6;
      jpeg_gate_unrelated_leak();
      [inner release];
    }
  /* Leave the test-only IMP installed until process exit so the recorder's
     final Objective-C method dump names the real stack correctly. */
  scrub_stack();
  printf("test-only JPEG probe calls: %u; real TIFF/PNG decode completed\n",
         probe_calls);
  [rep release];
  [pool release];
  return probe_calls == 0 ? 7 : 0;
}
