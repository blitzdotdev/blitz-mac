# App Store Screenshot Design Reference

> Structured prompt context for an AI design agent generating promotional App Store screenshots.

---

## 1. Required Dimensions and Technical Specifications

### Primary Submission Sizes (Mandatory)

Apple auto-scales from these to smaller devices. These are the only two you **must** provide:

| Device | Display | Portrait (px) | Landscape (px) |
|--------|---------|---------------|-----------------|
| **iPhone** | 6.9" (iPhone 16 Pro Max, 15 Pro Max) | 1260 x 2736 | 2736 x 1260 |
| **iPad** | 13" (iPad Pro M4/M5, iPad Air M3/M4) | 2064 x 2752 | 2752 x 2064 |

### All iPhone Sizes

| Display | Devices | Portrait (px) | Landscape (px) |
|---------|---------|---------------|-----------------|
| 6.9" | iPhone Air, 17 Pro Max, 16 Pro Max, 16 Plus, 15 Pro Max, 15 Plus, 14 Pro Max | 1260 x 2736 | 2736 x 1260 |
| 6.5" | iPhone 14 Plus, 13 Pro Max, 12 Pro Max, 11 Pro Max, 11, XS Max, XR | 1284 x 2778 (or 1242 x 2688) | 2778 x 1284 (or 2688 x 1242) |
| 6.3" | iPhone 17 Pro, 17, 16 Pro, 16, 15 Pro, 15, 14 Pro | 1179 x 2556 or 1206 x 2622 | 2556 x 1179 or 2622 x 1206 |
| 6.1" | iPhone 17e, 16e, 14, 13, 12, 11 Pro, XS, X | 1170 x 2532 / 1125 x 2436 / 1080 x 2340 | Corresponding landscape |
| 5.5" | iPhone 8 Plus, 7 Plus, 6S Plus | 1242 x 2208 | 2208 x 1242 |
| 4.7" | iPhone SE (2nd/3rd), 8, 7, 6S, 6 | 750 x 1334 | 1334 x 750 |
| 4" | iPhone SE (1st), 5S, 5 | 640 x 1136 (with status bar) | 1136 x 640 |

### All iPad Sizes

| Display | Portrait (px) | Landscape (px) |
|---------|---------------|-----------------|
| 13" | 2064 x 2752 or 2048 x 2732 | 2752 x 2064 or 2732 x 2048 |
| 11" | 1488 x 2266 / 1668 x 2420 / 1668 x 2388 / 1640 x 2360 | Corresponding landscape |
| 10.5" | 1668 x 2224 | 2224 x 1668 |
| 9.7" | 1536 x 2048 (with status bar) | 2048 x 1536 |

### Other Platforms

| Platform | Dimensions (px) | Notes |
|----------|-----------------|-------|
| Mac | 2880 x 1800 / 2560 x 1600 / 1440 x 900 / 1280 x 800 | 16:10 aspect ratio required |
| Apple TV (4K) | 3840 x 2160 | Required for tvOS apps |
| Apple TV (1080p) | 1920 x 1080 | Alternative |
| Apple Vision Pro | 3840 x 2160 | Required for visionOS apps |
| Apple Watch Ultra 2/3 | 410 x 502 / 422 x 514 | Required for watchOS apps |
| Apple Watch Series 10/11 | 416 x 496 | |
| Apple Watch Series 7-9 | 396 x 484 | |

### File Format Requirements

- **Formats**: PNG (recommended for UI clarity) or JPEG
- **Color space**: RGB only (CMYK is rejected)
- **Transparency**: Not allowed -- images must be flattened, no alpha channels
- **Resolution**: 72 DPI minimum
- **Max file size**: 10 MB per image
- **Quantity**: 1-10 screenshots per localization
- **Pixel accuracy**: Dimensions must match specifications exactly; even small deviations cause upload errors

---

## 2. Design Styles and Themes

### Background Styles

| Style | Description | Best For | Design Notes |
|-------|-------------|----------|--------------|
| **Solid color** | Single bold, uniform color behind device/content | Strong brand identity, clean look | Use brand primary color or complementary color |
| **Gradient** | Smooth color transitions (linear, radial, mesh) | Modern/premium feel, visual depth | Mesh gradients trending in 2025-2026; avoid muddy transitions |
| **Photo/lifestyle** | Real-world imagery showing people using the app | Emotional connection, social proof | Show happy, engaged users in realistic scenarios |
| **Minimal/clean** | White or near-white with minimal elements | Luxury, productivity, utility apps | Let the UI speak; very effective on iOS |
| **Dark/moody** | Dark backgrounds (#0A0A0A to #1A1A1A range) | Matches dark mode trend; 82% of users prefer dark mode | High contrast with white/bright text |
| **Panoramic** | Single wide image sliced across multiple screenshots | Storytelling, visual intrigue, compels scrolling | Account for inter-screenshot gaps (~20px visual gap) |
| **Pattern/texture** | Geometric patterns, subtle textures behind content | Distinctive brand feel | Keep subtle so UI remains focal point |

### Device Frame Styles

| Style | Description | When to Use |
|-------|-------------|-------------|
| **Realistic device** | Actual iPhone/iPad frame with accurate bezels | Default professional choice; most recognizable |
| **Clay/matte mockup** | Solid-color device frames (white, black, custom color) | When device should not compete with UI colors |
| **Bezel-less/floating** | Screenshot without any device frame, just the UI with rounded corners | Ultra-modern, maximizes visible UI area |
| **Angled/3D perspective** | Device tilted at 15-30 degrees | Premium feel, adds visual interest and depth |
| **Flat centered** | Device straight-on, centered vertically | Clean, standard, easiest to read |
| **Shadow/elevated** | Device with drop shadow on background | Adds depth without 3D complexity |
| **No device** | Full-bleed app UI fills entire screenshot | Maximum immersion; common for games |

**Critical rule**: Always use current-generation device frames (iPhone 16 Pro era). Outdated frames (iPhone X era) signal an abandoned app. Never show Android device frames in iOS screenshots.

### Layout Patterns

| Pattern | Description | Effectiveness |
|---------|-------------|---------------|
| **Single device centered** | One phone centered with caption text above or below | Most common; clean and reliable |
| **Dual device** | Two screens side-by-side showing related features | Good for before/after or feature comparison |
| **Multi-device** | 3+ screens overlapping or arranged | Shows breadth of features; risk of clutter |
| **Panoramic/continuous** | Background flows across consecutive screenshots | Compelling scroll driver; design around gap spacing |
| **Zoomed feature highlight** | Magnified UI element with annotation arrows | Great for complex features that need explanation |
| **Split screen** | Screenshot divided into distinct zones (text zone + device zone) | Clear information hierarchy |
| **Full-bleed UI** | App screen fills entire screenshot, no frame | Immersive; common in games and media apps |
| **Overlapping cards** | Multiple UI screens layered at slight offsets | Creates curiosity; shows depth of functionality |

### Feature Callout Styles

- **Arrow annotations**: Thin arrows pointing to key UI elements
- **Magnification circles**: Zoomed-in circles highlighting specific buttons or data
- **Numbered steps**: Sequential numbers (1, 2, 3) showing a workflow
- **Badge/pill highlights**: Rounded rectangles around key features
- **Glow/emphasis**: Subtle glow or color highlight on important areas
- **Before/after**: Side-by-side comparison showing transformation

---

## 3. Typography Best Practices

### Font Selection

| Category | Recommended Fonts | Notes |
|----------|-------------------|-------|
| **System/safe** | SF Pro Display, SF Pro Text (Apple ecosystem) | Familiar, readable, platform-native |
| **Modern sans-serif** | Inter, Poppins, Manrope, Plus Jakarta Sans | Clean, geometric, excellent at small sizes |
| **Bold/impact** | Montserrat Bold, Raleway Black, Outfit | High-impact headlines |
| **Geometric** | DM Sans, Urbanist, Satoshi | Trendy, modern feel |
| **Premium** | Playfair Display, Cormorant (serif accents) | Luxury/premium positioning |

### Text Hierarchy Pattern

```
HEADLINE (Primary message)
  - 2-5 words maximum
  - Bold/Black weight
  - Largest text element
  - Benefit-driven ("Sleep Better" not "Sleep Tracking Settings")

Subheadline (Supporting detail) [optional]
  - 5-10 words maximum
  - Regular/Medium weight
  - 50-60% of headline size
  - Feature-descriptive or explanatory
```

### Text Placement Strategies

| Placement | Pros | Cons |
|-----------|------|------|
| **Above device** | Clear separation, easy to read | Reduces device display size |
| **Below device** | Natural reading flow (scan down) | May get cut off in search results |
| **Overlay on background** | Integrated feel, saves space | Needs high contrast management |
| **Overlay on device screen** | Immersive | Obscures UI; avoid for App Store |
| **Left/right of device** | Works for landscape; editorial feel | Requires wider thinking |

### Readability Rules

- **The Glance Test**: Text must be readable from arm's length on a phone screen
- **Minimum effective size**: Treat captions as headlines, not body text; use massive font sizes
- **Maximum words per screenshot**: 5-7 words for primary caption; fewer is better
- **Contrast**: Always ensure high contrast between text and background; use drop shadows or semi-transparent text boxes if needed
- **Safe area**: Keep text away from edges; account for rounded corners on modern devices
- **Consistency**: Same font family, weight hierarchy, and color across all screenshots

---

## 4. Color and Visual Trends (2024-2026)

### Color Psychology by App Category

| Category | Primary Colors | Effect |
|----------|---------------|--------|
| Finance / Banking | Blue, deep navy, green | Credibility, safety, trust |
| Health / Wellness | Green, teal, soft blue | Calm, natural, healing |
| Games / Entertainment | Red, orange, yellow | Excitement, urgency, energy |
| Productivity / Utility | Blue, white, gray | Professional, clean, efficient |
| Social / Communication | Vibrant purple, pink, coral | Fun, connection, warmth |
| Food / Delivery | Red, orange, warm yellow | Appetite, speed, warmth |
| Travel | Blue, turquoise, sky tones | Freedom, aspiration, adventure |
| Premium / Luxury | Black, gold, deep purple | Sophistication, exclusivity |

### Trending Palettes (2025-2026)

- **Dark bases with neon accents**: Deep charcoal/black backgrounds with electric blue, neon green, or vivid purple highlights
- **Muted bases + vibrant accents**: Soft gray/cream backgrounds with one saturated accent color
- **Monochromatic gradients**: Single-hue gradients from light to dark (e.g., light blue to navy)
- **Earth tones + tech**: Warm neutrals (sand, terracotta) paired with modern UI elements
- **Glassmorphism backgrounds**: Frosted glass effects with subtle color blurs behind content

### Dark Mode vs Light Mode

- ~82% of smartphone users prefer dark mode
- Design screenshots for both if the app supports it; include at least one dark mode screenshot
- Dark backgrounds make colorful UI elements pop and feel premium
- Light mode screenshots still perform well for productivity, education, and family-oriented apps
- Neutral backgrounds (not pure white or pure black) work across both contexts

### Brand Color Integration

- Lead with brand colors for recognition, especially for established brands
- Use the app icon's color palette as the starting point for screenshot backgrounds
- Maintain a uniform palette across all 10 screenshots; switching colors mid-sequence creates cognitive load and signals low quality

---

## 5. Screenshot Sequence Strategy

### The First Three Rule

Users in search results see only 1-3 screenshots without tapping. These are your highest-impact slots.

| Slot | Purpose | Content Strategy |
|------|---------|-----------------|
| **#1 - The Hook** | Grab attention, communicate what the app IS | Primary value proposition; most compelling UI screen; bold headline |
| **#2 - The Solution** | Show emotional benefit or social proof | Key "aha!" feature; user testimonial; before/after |
| **#3 - The Payoff** | Seal interest, invite deeper exploration | Second most impressive feature; differentiation from competitors |
| **#4-7** | Feature showcase | One feature per screenshot; cover breadth of functionality |
| **#8-9** | Trust builders | Awards, ratings, media mentions, integrations |
| **#10** | Call to action or final impression | "Download now" messaging or summary of all benefits |

### Narrative Structures

- **A.I.D.A.**: Attention (what is it?) -> Interest (why should I care?) -> Desire (show the magic) -> Action (download now)
- **Problem-Solution**: Show the pain point -> Show the app solving it -> Show the outcome
- **Feature Tour**: Systematic walkthrough of top 5-7 features, one per screenshot
- **Story Arc**: User journey from onboarding to daily use to achieved results

---

## 6. Apple Guidelines and Rejection Avoidance

### Mandatory Rules

1. Screenshots must reflect actual in-app UI -- no fabricated screens or features that don't exist
2. File must be flattened PNG or JPEG in RGB color space, no transparency/alpha channels
3. Pixel dimensions must match specifications exactly
4. Only iOS device frames allowed; Android device frames cause immediate rejection
5. No misspelled words or bad grammar in overlay text
6. Content must not mislead about app functionality or capabilities
7. Up to 10 screenshots per localization

### Common Rejection Triggers

| Issue | Why It Fails | Fix |
|-------|-------------|-----|
| Outdated screenshots | UI doesn't match current app version | Update screenshots with every major release |
| Fabricated UI | Shows features/screens that don't exist in the app | Only show real, functional screens |
| Wrong dimensions | Even 1-2 pixel deviation | Use exact specs; validate before upload |
| CMYK color profile | Apple requires RGB | Export as sRGB |
| Alpha channel/transparency | Apple requires flattened files | Flatten all layers; export without alpha |
| Android device frames | Platform mismatch | Use iOS device frames exclusively |
| Broken promises | Description/screenshots show unavailable features | Align screenshots with shipping functionality |
| Placeholder content | Lorem ipsum, fake names, empty states | Use realistic (but not real user) data |

### Safe Practices

- Always show real app UI captured from the actual running application
- Device frames, background colors, and promotional text overlays are allowed and standard practice
- Include at least one Dark Mode screenshot if the app supports it
- Localize screenshots for each target market (not just translating text -- adapt visuals culturally)
- Use Apple's Product Page Optimization (PPO) for A/B testing screenshot variants
- Update screenshots seasonally or with major feature releases to signal active development

---

## 7. Localization Considerations

| Market | Design Preference | Notes |
|--------|-------------------|-------|
| US / Western | Minimalist, clean, benefit-driven | White space, short captions, emotional appeal |
| Japan | High information density | More text, detailed feature callouts, specific color usage |
| Korea | Bold visuals, character-driven | Trendy aesthetics, bright colors |
| Germany / DACH | Functional, feature-focused | Practical messaging, less emotional |
| Middle East | RTL layout consideration | Mirror layouts for Arabic/Hebrew |

---

## 8. Design Agent Prompt Context Template

When generating screenshots, the AI agent should consider the following parameters:

```
REQUIRED INPUTS:
- app_name: string
- app_category: string (e.g., "Finance", "Health", "Games")
- brand_colors: array of hex codes
- target_device: string (e.g., "iPhone 6.9\"")
- screenshot_slot: number (1-10)
- headline_text: string (2-5 words)
- subheadline_text: string (optional, 5-10 words)
- ui_screenshot: image (actual app screen capture)

DESIGN PARAMETERS:
- background_style: "solid" | "gradient" | "mesh_gradient" | "dark" | "photo" | "panoramic" | "pattern"
- background_color: hex or gradient definition
- device_frame_style: "realistic" | "clay" | "bezel_less" | "angled" | "flat" | "shadow" | "none"
- device_frame_color: hex (for clay style)
- text_placement: "above" | "below" | "overlay" | "left" | "right"
- font_family: string
- font_weight_headline: "Bold" | "Black" | "ExtraBold"
- font_weight_subheadline: "Regular" | "Medium" | "SemiBold"
- text_color: hex
- text_alignment: "center" | "left" | "right"
- dark_mode: boolean
- locale: string (e.g., "en-US", "ja-JP")

OUTPUT SPECS:
- dimensions: exact pixel dimensions for target device
- format: PNG (recommended) or JPEG
- color_space: sRGB
- no_alpha: true
- dpi: 72
```

---

## 9. Quick Reference: Design Checklist

- [ ] First 3 screenshots convey core value proposition
- [ ] Headlines are 2-5 words, benefit-driven
- [ ] Text passes the "glance test" (readable at arm's length on phone)
- [ ] Consistent font, color palette, and style across all screenshots
- [ ] Current-generation device frames used
- [ ] Pixel dimensions match Apple specs exactly
- [ ] Exported as flattened PNG/JPEG in sRGB, no alpha
- [ ] Real app UI shown (no fabricated screens)
- [ ] No placeholder/lorem ipsum content
- [ ] At least one dark mode screenshot (if app supports it)
- [ ] Localized for target markets (beyond just translation)
- [ ] Background style matches app category expectations
- [ ] High contrast between text and background
- [ ] No Android device frames or UI elements
- [ ] File size under 10 MB per image

---

*Sources: Apple Developer Documentation, SplitMetrics, AppScreenshotStudio, Moburst, Adapty, MobileAction, AppTweak, ASOMobile*
