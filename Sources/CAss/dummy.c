// CAss is a modulemap-only target (headers + link directives over the
// libass/freetype/fribidi binary targets).  SwiftPM requires at least one
// compilable source per C target or the linker fails with "CAss.o not found"
// — same trick as CFFmpeg/dummy.c.
