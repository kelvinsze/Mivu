# Mivu Design System v1.2

> iOS / iPadOS / CarPlay · Emby Media Player\
> Status: Implementation Specification\
> Design direction: **Content First · Neutral · Cinematic ·
> Apple-native**

------------------------------------------------------------------------

## 1. Product Design Principles

Mivu is a media player and Emby client, not a server administration
dashboard. The interface should feel closer to a first-party Apple media
application than a traditional Emby/Jellyfin client.

### Core principles

1.  **Content First** --- Posters, backdrops, titles and playback state
    are visually dominant.
2.  **Neutral Chrome** --- UI controls stay primarily monochrome; brand
    color is used selectively.
3.  **Cinematic Playback** --- Playback surfaces use true black and
    minimal visual interference.
4.  **Apple-native** --- Prefer native navigation, controls, typography,
    materials and SF Symbols.
5.  **Low Cognitive Load** --- Especially on CarPlay, expose only
    actions necessary for immediate playback.
6.  **Consistent, not identical** --- iPhone, iPad and CarPlay share
    tokens and identity but use platform-appropriate layouts.

------------------------------------------------------------------------

## 2. Brand Direction

### Visual keywords

**Charcoal · Warm White · Amber · Symmetrical Folded M · SF Pro · SF Symbols · 8pt Grid · 2:3
Posters · Minimal Chrome**

Mivu should avoid the visual language of a technical media-server
dashboard:

-   no excessive borders;
-   no large numbers of colored badges;
-   no persistent codec/bitrate information in normal browsing;
-   no heavy card shadows;
-   no unnecessary gradients;
-   no custom controls where native equivalents are sufficient.

Brand identity should primarily come from:

-   Mivu app icon and logo;
-   Accent color;
-   typography hierarchy;
-   consistent poster treatment;
-   playback UI;
-   motion and interaction details.

------------------------------------------------------------------------

## 3. Color System

Use semantic/dynamic system colors whenever possible. Hex values below
define visual targets and may be used for custom surfaces where system
semantic colors are insufficient.

  --------------------------------------------------------------------------
  Token                Light             Dark              Usage
  -------------------- ----------------- ----------------- -----------------
  `Background`         `#F5F4F1`         `#111113`         Main page
                                                           background

  `Surface`            `#FFFFFF`         `#1C1C1E`         Cards, sheets,
                                                           elevated surfaces

  `SurfaceSecondary`   `#ECEAE6`         `#29292C`         Secondary
                                                           containers

  `PrimaryText`        `#171719`         `#F5F5F5`         Titles and
                                                           primary
                                                           information

  `SecondaryText`      `#6F6E6A`         `#A1A1A6`         Metadata

  `TertiaryText`       `#AEAEB2`         `#636366`         Weak/supporting
                                                           information

  `Separator`          `#00000014`       `#FFFFFF18`       Dividers

  `Accent`             `#E89A32`         `#F0A43A`         Mivu brand accent

  `Success`            System Green      System Green      Connected /
                                                           successful

  `Warning`            System Orange     System Orange     Transcoding /
                                                           warning

  `Error`              System Red        System Red        Failure /
                                                           destructive
                                                           action
  --------------------------------------------------------------------------


### Mivu Amber palette

```text
Accent        #F0A43A
Accent Hover  #E89A32
Accent Pressed#C97D20
Accent Light  #FFD28A

Light Background        #F5F4F1
Light Surface           #FFFFFF
Light Surface Secondary #ECEAE6
Light Primary Text      #171719
Light Secondary Text    #6F6E6A

Dark Background         #111113
Dark Surface            #1C1C1E
Dark Surface Secondary  #29292C
Dark Primary Text       #F5F5F5
Dark Secondary Text     #A1A1A6
```

Recommended visual ratio: approximately **60% background / 25% neutral surfaces / 10% Amber accent / 5% semantic colors**.

The Amber accent is a state and interaction color rather than a large decorative fill. It should be most visible in Play/Resume, playback progress, selected tabs, focus and active states.


### Accent usage

Accent is reserved for:

-   primary playback CTA;
-   selected navigation state;
-   current playback progress;
-   selected audio/subtitle option;
-   focused/active controls;
-   important interactive state.

Do **not** use Accent as:

-   page background;
-   large card background;
-   metadata text;
-   decorative gradient;
-   every clickable control.

Recommended screen-level Accent coverage: **\< 10%**.

------------------------------------------------------------------------

## 4. Typography

Use **SF Pro / system font only**.

Do not bundle a separate brand typeface for application UI.

  Role                Size Weight     Notes
  --------------- -------- ---------- -------------------------------
  Large Title           34 Bold       Major iPhone navigation title
  Page Title            28 Bold       Custom page headers
  Section Title         20 Semibold   Content sections
  Media Title           17 Semibold   Movie/episode/card title
  Body              15--17 Regular    Descriptions
  Metadata          13--15 Regular    Year, runtime, resolution
  Caption           11--12 Medium     Small labels
  Player Time           12 Medium     Use monospaced digits

### Rules

-   Support Dynamic Type where practical.
-   Use `monospacedDigit()` for changing playback time.
-   Prefer maximum 2 lines for poster titles.
-   Metadata should remain visually subordinate to title.
-   Avoid uppercase labels except very short technical badges such as
    `HDR`.

Example:

``` text
Dune: Part Two
2024 · 2h 46m · 4K · HDR10
Denis Villeneuve
```

------------------------------------------------------------------------

## 5. Spacing System

Use a consistent 4/8-based spacing scale.

``` text
SpaceXXS = 4
SpaceXS  = 8
SpaceS   = 12
SpaceM   = 16
SpaceL   = 24
SpaceXL  = 32
SpaceXXL = 48
```

### Page margins

-   iPhone compact: `16pt`
-   iPhone landscape: `20–24pt`
-   iPad: `24–32pt`
-   Modal/sheet internal padding: minimum `16pt`

Avoid arbitrary values such as 13, 19, 27 unless required by native
component geometry.

------------------------------------------------------------------------

## 6. Corner Radius

Keep radius vocabulary limited.

``` text
RadiusS  = 8
RadiusM  = 12
RadiusL  = 16
RadiusXL = 24
```

Recommended usage:

  Component                   Radius
  ------------------------- --------
  Poster                           8
  Small button/container       8--12
  Card                        12--16
  Large artwork/card              16
  Custom floating surface         24

Native controls should retain native corner geometry.

------------------------------------------------------------------------

## 7. Borders, Shadows and Materials

### Borders

Avoid borders as the primary method of establishing hierarchy.

If required:

``` text
Light: #00000014
Dark:  #FFFFFF18
```

Maximum normal stroke: `1px / 1pt`.

### Shadows

Poster/card shadows should be subtle or absent.

Do not use strong Android/web-style drop shadows.

### Materials

Use native Apple materials for:

-   navigation overlays;
-   sheets;
-   transient playback controls;
-   floating toolbars.

Do not stack multiple translucent materials over one another.

------------------------------------------------------------------------

## 8. Iconography

### Primary icon system

Use **SF Symbols** for approximately 95% of interface icons.

Weight:

-   Standard UI: `Regular`
-   Important player controls: `Medium`
-   CarPlay: `Semibold`

Use custom vectors only for:

-   Mivu logo;
-   Mivu-specific product concepts;
-   external service branding where legally appropriate.

### Symbol mapping

  Function           SF Symbol
  ------------------ -------------------------------------
  Home               `house` / `house.fill`
  Movies             `film`
  TV Shows           `play.rectangle.on.rectangle`
  Library            `rectangle.stack` / `.fill`
  Search             `magnifyingglass`
  Settings           `gearshape` / `.fill`
  Play               `play.fill`
  Pause              `pause.fill`
  Replay 15 sec      `gobackward.15`
  Forward 15 sec     `goforward.15`
  Subtitles          `captions.bubble`
  Audio              `waveform`
  AirPlay            `airplayvideo`
  External display   `rectangle.connected.to.line.below`
  More               `ellipsis`
  Download           `arrow.down.circle`
  Downloaded         `checkmark.circle.fill`
  Favorite           `heart` / `heart.fill`
  History            `clock.arrow.circlepath`
  Server             `server.rack`
  Network            `network`
  Back               `chevron.backward`
  Close              `xmark`
  Check              `checkmark`
  Info               `info.circle`

### Icon rules

-   Do not place icons inside circles unless the component requires a
    circular button.
-   Selected navigation may use `.fill`.
-   Avoid mixing unrelated icon families.
-   Do not draw custom Play/Pause/Search/Settings symbols.

------------------------------------------------------------------------

## 9. Poster Component

Poster is Mivu's primary visual component.

### Ratio

``` text
2:3
```

### Structure

``` text
┌─────────────┐
│             │
│   POSTER    │
│             │
│             │
└─────────────┘
Title
2026 · 4K · HDR
```

### Rules

-   Radius: `8pt`
-   Image uses aspect fill.
-   Title: maximum 2 lines.
-   Metadata: maximum 1 line where possible.
-   Avoid permanent shadows.
-   Missing artwork uses neutral placeholder, not Accent background.

### Playback progress

For partially watched content:

-   position: bottom edge of poster;
-   height: `2–3pt`;
-   inactive track: low-opacity white/gray;
-   progress: Accent;
-   do not add a separate progress card.

------------------------------------------------------------------------

## 10. Badges

Badges are exceptional metadata, not default metadata containers.

Acceptable examples:

``` text
NEW
HDR
DV
LIVE
```

Avoid turning the following into multiple badges:

``` text
4K / HEVC / 10-bit / 24fps / AAC / 7.1 / 68 Mbps
```

Technical information belongs in Media Info.

Badge rules:

-   compact;
-   neutral by default;
-   maximum 1--2 visible badges per poster/card;
-   avoid bright colors unless communicating status.

------------------------------------------------------------------------

## 11. iPhone Navigation

Primary Tab Bar:

1.  Home
2.  Library
3.  Search
4.  Settings

Symbols:

``` text
Home      house.fill
Library   rectangle.stack.fill
Search    magnifyingglass
Settings  gearshape.fill
```

Prefer native system Tab Bar behavior and appearance.

Do not build a custom floating tab bar unless a platform limitation
requires it.

------------------------------------------------------------------------

## 12. Home Screen

Recommended hierarchy:

``` text
Mivu                              Search

Continue Watching
[ Poster ] [ Poster ] [ Poster ]

Recently Added
[ Poster ] [ Poster ] [ Poster ]

Movies                                   >
[ Poster ] [ Poster ] [ Poster ]

TV Shows                                 >
[ Poster ] [ Poster ] [ Poster ]
```

### Rules

-   Continue Watching is normally first when content exists.
-   Horizontal shelves should use consistent card dimensions.
-   Do not overload the first screen with server statistics.
-   No connection status banner when everything is healthy.
-   Server errors appear contextually only when action is required.

------------------------------------------------------------------------

## 13. Library

Library is optimized for browsing rather than administration.

Recommended top-level filters:

``` text
Movies
TV Shows
Collections
Favorites
Downloads
```

Optional sorting:

``` text
Recently Added
Title
Release Date
Date Played
Rating
```

Filters should use native menus/sheets instead of persistent control
panels.

------------------------------------------------------------------------

## 14. Search

Search should be immediate and media-centric.

Structure:

``` text
[ Search Movies, Shows, Episodes ]

Recent Searches

Results
Movies
TV Shows
Episodes
People
```

Rules:

-   native search field;
-   debounce remote Emby requests;
-   preserve recent searches locally where appropriate;
-   show useful empty state;
-   do not require selecting media type before searching.

------------------------------------------------------------------------

## 15. Media Detail Screen

Recommended hierarchy:

``` text
             BACKDROP

Dune: Part Two

2024 · 2h 46m · PG-13 · 4K HDR

[ ▶ Play ]          [ + ]

Rating / External Ratings

Overview

Cast

More Like This
```

### Backdrop

-   full-width;
-   cinematic crop;
-   fade naturally into Background;
-   ensure title remains readable;
-   avoid excessive blur.

Suggested bottom fade:

``` text
transparent
→ background with increasing opacity
→ Background
```

### Primary action

`Play` / `Resume` is the strongest CTA.

Accent should normally appear here.

Secondary actions stay neutral.

------------------------------------------------------------------------

## 16. TV Series Detail

Hierarchy:

``` text
Backdrop
Series Title
Year · Rating · Status

[ ▶ Resume ]

Season Picker

Episode 1
Thumbnail
Episode title
Runtime · progress
Description

Episode 2
...
```

Season selection should use native menu/sheet where appropriate.

Do not display every season as a permanent segmented control if the
number of seasons can become large.

------------------------------------------------------------------------

## 17. Player --- Visual Foundation

Player background:

``` text
#000000
```

Player controls:

``` text
Primary: white
Secondary: white at reduced opacity
Accent: current/selected state only
```

Video remains the visual focus.

### Standard overlay

``` text
‹                                      ···

                  VIDEO


             ◀15     ▶︎     15▶


──────────────●────────────────────────
01:14:23                              -32:17

        Audio     Subtitle     AirPlay
```

### Control overlay

When controls are visible, optional video dimming:

``` text
Black 20–30%
```

Avoid placing the entire control system inside a large blurred card.

------------------------------------------------------------------------

## 18. Player Controls

Primary:

-   Play/Pause
-   Seek
-   ±15 seconds
-   Close/Back

Secondary:

-   Audio track
-   Subtitle
-   AirPlay
-   Playback speed
-   Aspect/zoom where supported
-   Media info
-   More

Technical diagnostics should live behind `More > Media Info`.

------------------------------------------------------------------------

## 19. Playback Progress

Track:

-   neutral;
-   thin;
-   sufficiently large hit target despite thin visual line.

Progress:

-   Accent.

Buffered:

-   lighter neutral layer.

Thumb:

-   visible when actively seeking;
-   may become less prominent or hidden during passive playback.

Time:

``` swift
.monospacedDigit()
```

------------------------------------------------------------------------

## 20. Audio & Subtitle Sheet

Use a native sheet.

Example:

``` text
Audio

✓ English — EAC3 5.1
  Chinese — AAC 2.0

Subtitles

✓ Chinese Simplified
  English
  Off
```

Selection:

-   checkmark;
-   optional Accent;
-   no separate Save button if switching can happen immediately.

Codec information may appear as secondary text but should not dominate.

------------------------------------------------------------------------

## 21. Media Info

Technical information is intentionally separated from normal playback
UI.

Suggested fields:

``` text
Playback
Direct Play / Direct Stream / Transcode

Video
HEVC Main 10
3840 × 2160
23.976 fps
HDR10
68.4 Mbps

Audio
E-AC-3
5.1
640 kbps

Server
Emby Server
Latency
Current bitrate
```

Use monospaced digits where values change frequently.

------------------------------------------------------------------------

## 22. Loading States

Prefer:

1.  existing cached artwork/content;
2.  skeleton placeholder;
3.  subtle progress indicator.

Avoid full-screen spinners for ordinary content refreshes.

Player buffering may show a centered progress indicator after a short
delay to prevent flicker.

------------------------------------------------------------------------

## 23. Empty States

Keep empty states short.

Example:

``` text
No Downloads

Downloaded movies and episodes
will appear here.
```

Optional single CTA:

``` text
Browse Library
```

Do not add decorative illustrations unless they materially improve
comprehension.

------------------------------------------------------------------------

## 24. Error States

Errors should answer:

1.  What failed?
2.  Does playback/browsing still work?
3.  What can the user do?

Example:

``` text
Unable to Reach Server

Check your connection or verify that the
Emby server is available.

[ Try Again ]
```

Do not expose raw networking errors by default.

Technical details may be placed under:

``` text
Show Details
```

------------------------------------------------------------------------

## 25. Server Connection UI

Server configuration belongs in Settings/onboarding, not the Home
screen.

Recommended structure:

``` text
Servers

● Home Server
  Connected

  Remote Server
  Offline
```

Green should not be used as a large persistent decoration.

A small status indicator is sufficient.

------------------------------------------------------------------------

## 26. Settings

Suggested sections:

``` text
Playback
  Preferred Quality
  Direct Play
  Cellular Streaming
  Default Audio
  Default Subtitle

Appearance
  System / Light / Dark
  Poster Density

Downloads
  Quality
  Storage

Servers
  Manage Servers

Advanced
  Player Engine
  Network
  Diagnostics

About
  Mivu
  Version
```

Advanced options should remain out of the normal browsing path.

------------------------------------------------------------------------

# CarPlay

## 27. CarPlay Philosophy

CarPlay is a separate interaction environment.

Do not mirror the iPhone application screen.

Goals:

-   minimal decisions;
-   large targets;
-   immediate resume/playback;
-   high contrast;
-   shallow hierarchy;
-   no server administration;
-   no technical playback configuration while driving.

CarPlay implementation must remain within Apple's permitted CarPlay
templates and entitlement behavior.

------------------------------------------------------------------------

## 28. CarPlay Information Architecture

Recommended top-level content:

``` text
Mivu

Continue Watching

Recently Played

Movies / Shows / Library
```

Priority:

``` text
Resume > Recent > Library
```

Do not prioritize discovery complexity.

------------------------------------------------------------------------

## 29. CarPlay Home

Conceptual structure:

``` text
Mivu

Continue Watching
Dune: Part Two
Silo
Severance

Recently Played
...

Library
```

Artwork should be immediately recognizable.

Text should be short.

Avoid secondary metadata unless essential.

------------------------------------------------------------------------

## 30. CarPlay Now Playing

Conceptual structure:

``` text
          Artwork

      Dune: Part Two
        Mivu · Emby

       ◀15   ▶︎   15▶
```

Primary controls:

-   Play/Pause
-   Previous/rewind
-   Next/forward
-   permitted native Now Playing controls

Do not expose directly:

-   codecs;
-   bitrate;
-   server IP;
-   transcoding controls;
-   detailed subtitle configuration;
-   media diagnostics.

------------------------------------------------------------------------

## 31. CarPlay Icon Rules

CarPlay icons should be:

-   monochrome;
-   high contrast;
-   visually heavier than iPhone equivalents;
-   SF Symbols where available;
-   simple silhouettes;
-   recognizable without text where possible.

Recommended weight:

``` text
Semibold
```

Avoid thin-line icons.

------------------------------------------------------------------------

## 32. CarPlay Color

Use the platform-provided environment as the foundation.

Mivu Accent should be used only where CarPlay APIs/templates permit and
where it does not reduce readability.

Never rely solely on color to communicate:

-   playback status;
-   selected item;
-   error;
-   connectivity.

------------------------------------------------------------------------

# Responsive Design

## 33. iPad

iPad should not simply stretch iPhone shelves.

Recommended changes:

-   wider content margins;
-   denser poster grids;
-   sidebar/navigation split view where useful;
-   persistent library navigation on large widths;
-   detail views may use two-column layouts;
-   player can expose additional secondary controls.

Poster ratio remains `2:3`.

------------------------------------------------------------------------

## 34. Landscape

Landscape priorities:

1.  maximize media/artwork;
2.  keep controls reachable;
3.  avoid overly wide text;
4.  adapt grids rather than stretching cards.

Media detail descriptions should use a readable maximum width.

------------------------------------------------------------------------

# Motion & Interaction

## 35. Animation

Animation should be functional.

Recommended durations:

``` text
Micro interaction: 0.15–0.20s
Standard transition: 0.20–0.30s
Artwork transition: 0.25–0.35s
```

Use spring animation only where it improves perceived responsiveness.

Avoid:

-   bouncing every card;
-   decorative parallax;
-   large zoom transitions that delay navigation.

Respect Reduce Motion.

------------------------------------------------------------------------

## 36. Haptics

Use sparingly.

Appropriate:

-   successful selection of a significant playback option;
-   favorite/download action;
-   destructive confirmation;
-   seek snap point where useful.

Do not trigger haptics for routine scrolling/navigation.

------------------------------------------------------------------------

# Accessibility

## 37. Accessibility Requirements

Mivu should support:

-   Dynamic Type;
-   VoiceOver;
-   Reduce Motion;
-   Increase Contrast;
-   Reduce Transparency where applicable;
-   sufficient contrast;
-   minimum practical touch targets;
-   non-color-only state communication.

Artwork must expose meaningful accessibility labels.

Example:

``` text
"Dune: Part Two, partially watched, 42 minutes remaining"
```

instead of:

``` text
"poster image"
```

------------------------------------------------------------------------

# Brand Asset

## 38. Mivu Logo Direction

The Mivu brand mark is the **Symmetrical Folded M**.

It is a standalone product symbol rather than a literal playback icon. Do not add a play triangle, screen outline, aperture, dot, or other media pictogram to the core mark. Media meaning should come from the product context and the folded, forward-moving geometry rather than an explicit ▶ symbol.

### Geometry

-   The mark is fully symmetrical on its vertical axis.
-   Left and right peaks, legs and outer silhouette use matching geometry.
-   The center valley remains centered.
-   Preserve the same master vector geometry across app icon, launch/brand surfaces and marketing assets.
-   Do not create asymmetric variants for individual screens.
-   Avoid fine internal lines and fragile details.

### Fold treatment

The full-color brand mark may use restrained tonal separation to communicate a folded ribbon:

``` text
Primary Amber     #F0A43A
Secondary Amber   #E89A32
Fold Shadow       #C97D20
Highlight         #FFD28A (sparingly)
```

The fold treatment should remain subtle: approximately **70% geometric logo / 30% dimensional fold**. Avoid metallic reflections, glossy material effects or strong 3D rendering.

The dimensional treatment is a **brand-asset exception**. It does not authorize gradient-heavy buttons, cards, navigation or other application UI.

### Required variants

1.  **Full Color** — Amber Folded M on charcoal; primary brand presentation.
2.  **Monochrome** — single-color silhouette for small UI, CarPlay and constrained contexts.
3.  **Tinted/System** — geometry adapted to platform icon tinting while preserving the Folded M silhouette.

The mark must remain recognizable at App Icon size, approximately 16–20pt UI usage where appropriate, CarPlay display size, and monochrome rendering.

--------------------------------------------------------------------------

## 39. App Icon

### Final concept

``` text
Neutral charcoal field
+
Symmetrical Folded M
+
restrained Amber fold treatment
```

Recommended background target:

``` text
#111113 → #080809
```

Use only a very subtle neutral tonal transition if needed. Do not introduce a brown/orange glow behind the mark. The background should read as charcoal/near-black, not as a decorative gradient.

### Composition

-   Center the Folded M optically and geometrically.
-   Preserve generous negative space around the symbol.
-   The M should not touch or visually crowd the icon boundary.
-   Do not place the word `Mivu` inside the app icon.
-   Do not add playback triangles, screens, rings or secondary symbols.
-   Do not change the master M geometry between icon appearances.

### Platform appearances

Prepare and verify:

-   Default;
-   Dark;
-   Tinted;
-   Clear, if required by the target OS/design workflow.

For Tinted/monochrome rendering, remove fold gradients when necessary and prioritize the clean Folded M silhouette.

### Small-size behavior

At small sizes, silhouette recognition takes priority over dimensional detail. Reduce or remove highlight/shadow separation before altering geometry.

For CarPlay or other small monochrome placements, use the **single-color symmetrical Folded M**, not a miniature full-gradient app icon.

--------------------------------------------------------------------------

# SwiftUI Implementation Tokens

## 40. Suggested Token Structure

``` swift
enum MivuSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

enum MivuRadius {
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}
```

### Semantic colors

Prefer SwiftUI semantic colors for standard system concepts.

Create Mivu-specific tokens only where necessary:

``` swift
extension Color {
    static let mivuAccent = Color("MivuAccent")
    static let mivuBackground = Color("MivuBackground")
    static let mivuSurface = Color("MivuSurface")
    static let mivuSurfaceSecondary = Color("MivuSurfaceSecondary")
}
```

Do not scatter raw Hex/RGB values throughout feature code.

------------------------------------------------------------------------

## 41. Component Naming

Recommended reusable components:

``` text
MivuPosterCard
MivuLandscapeCard
MivuMediaRow
MivuSectionHeader
MivuMetadataLine
MivuBadge
MivuProgressBar
MivuPrimaryButton
MivuEmptyState
MivuErrorState
MivuArtworkPlaceholder
MivuServerStatus
MivuPlayerControls
MivuMediaInfoView
```

Features should compose these components rather than reimplementing
visual rules.

------------------------------------------------------------------------

## 42. Poster Size Strategy

Do not hardcode one universal poster width.

Use semantic sizes:

``` text
compact
standard
large
```

Example target ranges:

  Context                           Width
  -------------------------- ------------
  Compact horizontal shelf     110--125pt
  Standard iPhone shelf        125--145pt
  iPad grid                      adaptive
  Large featured poster            160pt+

Always preserve `2:3`.

------------------------------------------------------------------------

# Engineering Rules

## 43. UI Implementation Priorities

When refactoring existing Mivu UI, use this order:

1.  Establish tokens.
2.  Replace arbitrary colors.
3.  Normalize typography.
4.  Normalize spacing/radius.
5.  Replace custom common icons with SF Symbols.
6.  Build reusable poster/media components.
7.  Refactor Home.
8.  Refactor Media Detail.
9.  Refactor Player.
10. Refactor Library/Search/Settings.
11. Adapt iPad.
12. Implement/normalize CarPlay presentation.
13. Accessibility pass.
14. Visual regression review.

Do not rewrite playback/networking logic solely for visual refactoring.

------------------------------------------------------------------------

## 44. Anti-patterns

Do not introduce:

-   gradient-heavy cards;
-   neon streaming-service styling;
-   permanent glass cards everywhere;
-   excessive shadows;
-   excessive pills;
-   multiple competing accent colors;
-   visible codec badges throughout the library;
-   custom tab bar without a functional reason;
-   tiny CarPlay controls;
-   server diagnostics on Home;
-   technical terminology in primary playback flows;
-   fixed font sizes that break accessibility;
-   raw RGB/Hex values throughout views.

------------------------------------------------------------------------

# Definition of Done

## 45. Visual Acceptance Checklist

A screen is considered compliant when:

-   [ ] Background/surface tokens are used consistently.
-   [ ] Accent is limited to meaningful interactive state.
-   [ ] SF Pro/system typography is used.
-   [ ] Common actions use SF Symbols.
-   [ ] Spacing follows the defined scale.
-   [ ] Radius follows the defined scale.
-   [ ] Poster artwork uses 2:3 ratio.
-   [ ] Metadata does not compete with title.
-   [ ] Technical media information is hidden from normal browsing.
-   [ ] Light and Dark appearances are both verified.
-   [ ] Dynamic Type does not break primary flows.
-   [ ] VoiceOver labels are meaningful.
-   [ ] Reduce Motion is respected.
-   [ ] iPad layout is adaptive rather than stretched.
-   [ ] CarPlay presents only driving-appropriate controls/content.

------------------------------------------------------------------------

## 46. Agent Refactor Instruction

When this document is provided to a coding agent:

> Treat this specification as the visual source of truth for Mivu. First
> inspect the existing codebase and identify existing reusable
> components, navigation architecture, playback implementation and
> CarPlay implementation. Refactor presentation incrementally without
> unnecessarily replacing working playback, Emby networking, persistence
> or decoding logic. Create shared design tokens and reusable components
> before modifying individual screens. Preserve existing functionality
> unless a change is explicitly required by this specification. Prefer
> native SwiftUI/UIKit/CarPlay APIs and SF Symbols over custom
> implementations. Verify all affected screens in Light/Dark Mode and
> appropriate device size classes.

------------------------------------------------------------------------

## 47. Final Design Summary

Mivu should feel like an independent Apple-platform media product rather
than a skinned Emby client.

The final visual hierarchy is:

``` text
CONTENT
↓
TITLE
↓
PLAYBACK STATE
↓
PRIMARY ACTION
↓
METADATA
↓
TECHNICAL INFORMATION
```

The defining visual system is:

``` text
Charcoal / Warm White
+ restrained Amber
+ Symmetrical Folded M
+ SF Pro
+ SF Symbols
+ 8pt-oriented spacing
+ 2:3 artwork
+ native Apple controls
+ minimal interface chrome
```

This specification applies to the Mivu iOS, iPadOS and CarPlay user
interface unless a platform API or CarPlay template imposes stricter
requirements.
