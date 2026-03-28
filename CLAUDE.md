# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development

No build step. Static files served directly.

```bash
python3 -m http.server 8080        # or use: npx serve
```

Dev server is configured in `.claude/launch.json` (preview_start uses this). No tests, no linter, no bundler.

Deployed to GitHub Pages via `.github/workflows/deploy.yml` on push to `main`.

## Architecture

Vanilla JS PWA — no framework, no build tools. Four modules loaded in order via `<script defer>`:

1. **cameras.js** — Data normalization (40+ US/Canadian DOT APIs each have different formats), corridor filtering (1km buffer with OSRM geometry, haversine verification fallback), route-position sorting, camera clustering
2. **api.js** — Stale-while-revalidate fetching with direct→CORS-proxy fallback chain. 5-min cache TTL. Falls back to bundled JSON (`data/cameras-*.json`) if APIs are unreachable. Progressive loading (regions fetch in parallel, render as they arrive). Also handles incident/event API fetching for notifications.
3. **map.js** — Leaflet map wrapper. Marker clustering, route polyline (OSRM geometry with straight-line fallback), traffic coloring (deterministic simulation), geolocation. Exposes ~14 public methods consumed by app.js
4. **app.js** — UI orchestration (~2,600 lines). Route selection (predefined + custom geocoded destinations), camera list rendering with clustering/pagination, modal image viewer with FLIP animation, pull-to-refresh, list↔map scroll sync, URL hash routing, generation-based stale load cancellation, incident push notifications

**Data flow:** `init()` → load `route.json` → restore prefs from localStorage → `loadCameras()` (predefined) or `loadCamerasForGeometry()` (custom routes, after OSRM) → fetch regions progressively → normalize → filter corridor → cluster → sort → render list + set map markers

## Key Patterns

- **Module pattern**: Each JS file is an IIFE returning a public API object (`TripMap`, `API`, `Cameras`)
- **Stale-while-revalidate**: Cache in localStorage + memory, serve stale instantly, background refresh
- **FLIP animation**: Modal opens by measuring source card rect → animating clone → revealing modal
- **List↔map sync**: Scroll list → highlight markers; pan map → scroll list to first visible camera. Debounced to prevent ping-pong
- **URL hash routing**: `#from={id}&to={id}&camera={id}` for shareable deep links
- **Route generation counter**: Cancels stale async camera loads when route changes mid-flight
- **Geocoding**: Photon/Komoot for custom origin/destination with reverse geocode for current location

## CSS

Single `styles.css` file. Mobile-first with desktop breakpoint at 769px (50/50 map+sidebar split). Light/dark via CSS custom properties + `prefers-color-scheme`. Spring easing curves defined as CSS variables. `prefers-reduced-motion` disables all animations.

## External Dependencies

- **Leaflet** v1.9.4 + MarkerCluster v1.5.3 (CDN, loaded in index.html)
- **Camera APIs**: 40+ US state DOTs and Canadian provincial APIs — IBI 511 platform (AB, SK, MB, ON, NB, NS, PE, NL, YT, NY, GA, WI, LA, AZ, ID, AK, UT, NV, CT), DriveBC, WSDOT, Caltrans (12 districts), ArcGIS (OR, WY, KY, DE), and custom formats (MD, OH, ND, QC). All via corsproxy.io when direct CORS fails.
- **Incident APIs**: Same regional coverage for events/alerts — IBI 511 `/api/v2/get/event`, DriveBC events, WSDOT highway alerts, OHGO incidents, Maryland CHART, Oregon TripCheck
- **OSRM**: Road geometry for route polylines (24h localStorage cache)

## Service Worker

`sw.js` handles offline: static assets use stale-while-revalidate, camera images cache-first (30min, 200 max), map tiles cache-first (24h, 500 max), API data network-first with cache fallback. Also handles incident push notifications (show notification on message from app, navigate to map location on click). **Important:** bump `CACHE_NAME` version in `sw.js` when changing JS files, otherwise users may get stale code from the SW cache.

## Incident Notifications

Polling-based push notifications for route incidents (no backend required). On page load, the app requests notification permission, then polls incident APIs every 3 minutes. The first poll silently seeds a baseline of existing incidents — only genuinely new incidents that appear in subsequent polls trigger notifications. Tapping a notification navigates the map to the incident location. Seen incidents are session-only (in-memory set, reset on page reload or route change). Corridor filtering uses the same OSRM geometry + buffer as camera filtering.
