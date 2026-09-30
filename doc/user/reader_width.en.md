# Reader Side Margins

中文版本：[reader_width.zh.md](reader_width.zh.md)

In **Settings → Reader** or from the reader's in-session settings panel, selecting **Continuous (Top to Bottom)** or **Waterfall (Top to Bottom)** exposes the **Side margins (each side)** slider. This setting also appears when automatic reader mode preferences include vertical flow modes.

## Layout and Margin Rules

- **Adjustment Range**: Supports 0%–30% on each side (default 0%). For example, setting 20% leaves 20% margin on both left and right sides of the content area, displaying centered images at 60% width with proportional height scaling.
- **Applicable Modes**: Applies exclusively to vertical continuous and waterfall reader modes. It does not affect Gallery (single/dual page) or horizontal continuous reading.
- **Interaction with Width Limit**: If **Limit image width** is enabled, that limit is applied first, followed by the percentage margin reduction. Percentages apply to the constrained content width rather than raw screen width.
- **Priority**: Follows per-comic, per-device, then global setting precedence. Changes take effect immediately in the active reader. Setting to 0% removes margins while preserving width limit settings.

## Alignment with Adaptive Layout Target

In VeneraNext, margin scaling is fully synchronized with the image loading layout constraints:

- When a comic source's `comic.onImageLoad` inspects the 4th parameter `target`, `ComicImageLoadTarget.logicalWidth` represents the **actual effective constrained width** after side margins are applied (rather than unscaled screen bounds).
- Display dimensions, image cache identities, preloading targets, and PhotoView viewports remain aligned, avoiding fetching or decoding unnecessarily large images when content is narrowed.
