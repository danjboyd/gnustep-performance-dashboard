/* +imageRepsWithData: on TIFF and PNG data: heap growth per call.  With a
   JPEG file as the argument, the same for that file, as a control.  Uses
   glibc's mallinfo2().

   cc `gnustep-config --objc-flags` jpeg_probe_leak.m -o jpeg_probe_leak \
     `gnustep-config --gui-libs`
   ./jpeg_probe_leak [file.jpg]  */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <malloc.h>
#include <stdio.h>

static long
growth(NSData *data, int calls)
{
  struct mallinfo2 before, after;
  int i;

  /* Warm up caches first.  */
  for (i = 0; i < 10; i++)
    {
      NSAutoreleasePool *pool = [NSAutoreleasePool new];
      [NSBitmapImageRep imageRepsWithData: data];
      [pool release];
    }
  before = mallinfo2();
  for (i = 0; i < calls; i++)
    {
      NSAutoreleasePool *pool = [NSAutoreleasePool new];
      [NSBitmapImageRep imageRepsWithData: data];
      [pool release];
    }
  after = mallinfo2();
  return (long)after.uordblks - (long)before.uordblks;
}

static void
report(const char *name, long bytes, int calls)
{
  printf("  %-4s %7ld bytes (%.1f per call)\n", name, bytes, bytes / (double)calls);
}

int
main(int argc, char **argv)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  NSBitmapImageRep *rep;
  NSData *tiff, *png, *jpeg = nil;
  int calls = 1000;

  rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL
                                                pixelsWide: 4
                                                pixelsHigh: 4
                                             bitsPerSample: 8
                                           samplesPerPixel: 3
                                                  hasAlpha: NO
                                                  isPlanar: NO
                                            colorSpaceName: NSDeviceRGBColorSpace
                                               bytesPerRow: 0
                                              bitsPerPixel: 0];
  tiff = [rep TIFFRepresentation];
  png = [rep representationUsingType: NSPNGFileType
                          properties: [NSDictionary dictionary]];
  if (argc > 1)
    jpeg = [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: argv[1]]];

  printf("%d calls each; heap growth (mallinfo2 uordblks):\n", calls);
  report("TIFF", growth(tiff, calls), calls);
  report("PNG", growth(png, calls), calls);
  if (jpeg != nil)
    report("JPEG", growth(jpeg, calls), calls);
  [rep release];
  [pool release];
  return 0;
}
