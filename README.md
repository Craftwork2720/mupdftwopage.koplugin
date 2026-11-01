# MuPDF two pages

A KOReader plugin that adds a two-page view to the built-in MuPDF reader, for
fixed-layout documents. It is independent of Meguru and works on the pages the
document already has: no download, no marker file, no new document type.

## Install

Copy the `mupdftwopage.koplugin` directory into `koreader/plugins/` and restart
KOReader. Tested with KOReader 2026.07.1.

## Use

Open a supported document in page view, then open the bottom config menu (tap
or swipe the config zone) and go to the page-view tab:

- **Two pages** — `off`, `in landscape`, or `always`.
- **Pair offset** — shifts the pairing of the run you are reading one page
  back. Setting it anchors the offset at the page on screen; a wide page ends
  it by itself.
- **Flexible gutter** — puts the spare screen width back into the cropped inner
  margins, without shrinking the artwork.

Long-press the name of **Two pages** or **Flexible gutter** to set it as the
default for new documents. The pair offset is per book: it names the page it
was set on, which means nothing in another book.

The pairing is the same as Meguru's: pages are shown in pairs, a page wider
than tall is shown alone, and the pairing starts again after it. The page
number, the sidecar, and the progress report always use the first page of the
pair.

## Scope

- MuPDF page view only. Reflow and continuous view turn the feature off.
- Fixed-layout MuPDF documents: PDF, CBZ/CBR/CBT, XPS, and any other format
  MuPDF opens with a fixed page count. Reflowable formats (EPUB, FB2, TXT,
  HTML, MOBI) are excluded because their page count changes with the layout.
- The reader's own reading direction is used for which page of a pair is the
  left-hand one, so a manga document set to inverted page turns reads right to
  left.
- Text selection, links, and saved highlights follow the page under the
  finger on both halves of the pair. Page-based features that ask the
  document for a single page still get that page's own size.
