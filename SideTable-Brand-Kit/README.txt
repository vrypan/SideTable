SIDETABLE BRAND KIT - VERSION 1.0

START HERE
Brand guide: guide/SideTable-Brand-Guide.pdf
Website header: vector/sidetable-logo-horizontal-black.svg
Primary logo: vector/sidetable-logo-stacked-black.svg
App symbol: vector/sidetable-mark-black.svg

FORMATS
SVG: editable vector paths, infinitely scalable, outlined wordmarks.
PDF: vector logo masters for design and print; guide is separate.
PNG: RGBA transparent logos, black and white variants.
ICO: multi-resolution Windows icon and browser favicon, 16-256 px.
ICNS: macOS icon bundle, with original .iconset directory.

RASTER DIMENSIONS
Marks: square 128, 256, 512, 1024, 2048 px.
Wordmarks and lockups: 512, 1024, 2048 px wide; aspect ratio preserved.
Mobile/full-square light and dark masters:
16, 20, 24, 29, 32, 40, 48, 58, 60, 64, 76, 80, 87, 96, 120,
128, 152, 167, 180, 192, 256, 512, 1024 px.
macOS iconset: 16, 32, 128, 256, 512 pt at 1x and 2x.
Web: 16/32/48/64/128/256 px favicons; 180 px touch icon;
192/512 px PWA icons and separate 512 px maskable icon.
Social: 1080x1080 avatars and square post; 1200x630 link-preview image.

USAGE
Use white transparent logos on dark backgrounds. White files can look
blank in a white image viewer. Full-square mobile masters are opaque;
platforms supply their own corner mask. The framed icon is for display.
macOS has a transparent outer margin. ICNS and ICO are ready to import.
Mobile PNGs are inputs, not complete Xcode/Android asset catalogs;
map them to the app's actual target configuration. Android adaptive
foreground/background layers and layered platform effects are not included.
The Windows icon uses the reinforced micro geometry for clarity.

WEB INSTALLATION
Copy the contents of web/ to your public root and use head-snippet.html.
For subdirectory hosting adjust all icon URLs and manifest start_url.
The manifest includes icon metadata; it does not implement offline support.
Set your own absolute public URL for social sharing image metadata.

DESIGN
Ink #111111; Paper #FFFFFF. Print one-color artwork as 100% K.
Poppins SemiBold wordmark, supplied as paths. No fonts are needed to
render the logo. Supporting typography: Poppins Regular or system sans.
The concept was reconstructed as clean geometry, not pixel-traced.
The approved upper-left chair offset is preserved intentionally.
The micro favicon has thicker backrests and wider gaps.
See source/geometry.json for exact dimensions.

MANIFEST
manifest.json lists files, sizes and SHA-256 checksums.
