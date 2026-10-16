/* PDInspectorView.h - the "Extended Detail" pane: a title, free text and a
   stack trace (symbol, library, optional source line).  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>

@interface PDInspectorView : NSView

- (void) showTitle: (NSString *)title
              text: (NSString *)text
             stack: (uint32_t)stack
           process: (GSPProcess *)process;
- (void) clear;

@end
