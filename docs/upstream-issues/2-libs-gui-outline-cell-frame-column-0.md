**Repository:** gnustep/libs-gui

**Status:** draft, not reviewed. Reproducer: `outline_column_frame.m`
(next to this file); screenshot: `outline_column_frame.png`.

**Checked before drafting (2026-10-16):** libs-gui issues and pull
requests, open and closed, searched for "frameOfOutlineCellAtRow",
"outlineTableColumn" and "outline column". The hits (#154, #265, #634, #635)
are about other things. `-frameOfOutlineCellAtRow:` is unchanged on master
since b4c98b329.

**Our workaround meanwhile:** Performance Dashboard keeps its outline
column first and turns off column reordering.

---

**Title:** NSOutlineView: -frameOfOutlineCellAtRow: always uses column 0, so the disclosure triangle is drawn outside the outline column

### Summary

When an outline view's outline column (`-setOutlineTableColumn:`) is not
its first column, the disclosure triangle is drawn in column 0. Clicks
are still only recognised in the outline column, so clicking the triangle
you can see does nothing, and the place that does expand the row shows no
triangle. The outline column's text is indented as if a triangle were
there.

### Steps to reproduce

The attached `outline_column_frame.m` creates an `NSOutlineView` with two
columns, 150 and 200 points wide, makes the second one the outline column,
and shows one expandable row. It prints the outline column's cell frame,
the result of `-frameOfOutlineCellAtRow: 0`, and whether a click at each
place expands the row:

```
outline column (column 1) cell, row 0: x 152 to 348
frameOfOutlineCellAtRow: 0:            x 2 to 148
click at x 7 (where the triangle is drawn) expands the item: no
click at x 157 (start of the outline column) expands the item: yes
```

On screen, the triangle is drawn over the start of column 0's text, and
column 1's text is indented with empty space where the triangle should be.

### Expected

`-frameOfOutlineCellAtRow:` returns a frame inside the outline column, so
the triangle is drawn where clicks expand the row.

### Cause

`-frameOfOutlineCellAtRow:` (Source/NSOutlineView.m, line 436 on master
fdc5cfe83) starts from the frame of column 0, not the outline column:

```objc
  frameRect = [self frameOfCellAtColumn: 0
				    row: row];
```

The theme draws the triangle at this frame
(`-[GSTheme drawOutlineCell:outlineView:item:drawingRect:rowIndex:]`,
Source/GSThemeDrawing.m, line 3575). `-mouseDown:` (Source/NSOutlineView.m,
line 949) checks that the click is in `_outlineTableColumn` and measures
from that column's origin (`_columnOrigins[_clickedColumn]`, line 980). So
drawing and hit-testing disagree whenever the outline column isn't column 0.

### Versions

Reproduced with the program above on Debian 13 x86_64, under Xvfb, against
libs-gui 0.32.0 (as installed) and against master fdc5cfe83 built from
source with clang 19.1.7. Same output on both.

Investigated, reproduced and written up with AI assistance (Claude).
