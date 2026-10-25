SIDETABLE BRAND KIT v2.0 - 25 October 2026
Golden yellow #FFD23F + espresso brown #3B2118

START HERE
apps/macos/SideTable.icns - macOS icon
apps/windows/SideTable.ico - Windows icon
web/ - browser favicons, touch icon and PWA assets
vector/sidetable-app-primary.svg - primary espresso-on-yellow icon
vector/sidetable-app-reversed.svg - yellow-on-espresso alternative
vector/sidetable-logo-horizontal-espresso.svg - transparent website header
vector/sidetable-logo-stacked-espresso.svg - transparent stacked logo
social/ - primary/reversed avatars, yellow share and square images
guide/ - PDF guide, agent Markdown guide and companion artwork

All logos preserve the approved geometry, including the upper-left offset.
Lettering is outlined Poppins SemiBold. No font installation is required.

VARIANTS
Espresso and yellow transparent SVG/PDF/PNG variants are the brand colors.
Black and white variants are monochrome fallbacks, not primary colors.
Primary app icons use espresso artwork on golden yellow.
Reversed app icons use yellow artwork on espresso.
macOS and Windows bundles use the primary color treatment.
The framed preview and macOS tile have rounded corners; mobile masters
are opaque full squares so the target platform can apply its own mask.

SIZES
Transparent marks: 128, 256, 512, 1024, 2048 px square.
Logo/wordmark PNGs: 512, 1024, 2048 px wide; original aspect ratio.
Mobile PNGs: 16, 20, 24, 29, 32, 40, 48, 58, 60, 64, 76, 80, 87,
96, 120, 128, 152, 167, 180, 192, 256, 512, 1024 px.
macOS iconset: 16, 32, 128, 256, 512 pt at 1x and 2x.
Windows ICO/browser favicon: 16, 32, 48, 64, 128, 256 px.
Touch icon: 180 px. PWA icons: 192/512 px; maskable: 512 px.
Social avatars and square post: 1080x1080; share image: 1200x630.
Micro geometry strengthens backrests at tiny sizes. Web favicons and
Windows ICO use micro geometry; mobile and macOS use it at 16-24 px.

IMPLEMENTATION
Use SVG for responsive layouts, PNG for fixed raster placements.
Transparent yellow/white artwork needs a contrasting background.
Mobile PNGs are inputs, not complete Xcode or Android asset catalogs.
No Android adaptive layers or layered platform icon effects are included.
Copy web/ to your public root and use head-snippet.html. Adjust paths
and manifest start_url for subdirectory hosting. Manifest icon metadata
does not implement offline support. Set your public URL for social metadata.

FILES
manifest.json lists file sizes and SHA-256 checksums.
Original version 1 files are preserved outside this separate v2 package.
