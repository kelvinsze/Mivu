# Unified Ratings API

A high-performance, resilient, self-hosted media ratings aggregator backend for **Mivu** (iOS / iPadOS / macOS / tvOS media player), built with **Cloudflare Workers**, **Cloudflare D1**, **TypeScript**, and **Hono**.

The client application communicates exclusively with this backend and does not directly depend on MDBList, Douban, Rotten Tomatoes, IMDb, Letterboxd, Metacritic, or other external rating providers.

---

## 1. Architecture Overview

```text
iOS / macOS / tvOS (Mivu Client)
        │
        │ HTTPS (optional Bearer Token Auth & Rate Limiting)
        ▼
┌────────────────────────────────────────────────────────┐
│ Unified Ratings API (Cloudflare Worker)                │
└────────────────────────────────────────────────────────┘
        │
        ├────────────────────────────┬─────────────────────────────┐
        ▼                            ▼                             ▼
┌────────────────┐           ┌───────────────┐             ┌──────────────┐
│ L1 Cache       │           │ D1 Database   │             │ In-flight    │
│ Cloudflare     │           │ media_identity│             │ Request      │
│ Cache API      │           │ ratings_cache │             │ Deduplication│
└────────────────┘           └───────────────┘             └──────────────┘
        │                            │
        │ Cache Miss / Expired       │
        ▼                            ▼
┌────────────────────────────────────────────────────────┐
│ Provider Adapters & Circuit Breaker                    │
└────────────────────────────────────────────────────────┘
        │                                         │
        ▼                                         ▼
┌───────────────────────────────┐         ┌──────────────────────────────┐
│ MDBList Aggregator API        │         │ Douban Scraper / Resolver    │
│ - IMDb (score & votes)        │         │ - ID Resolution (IMDb/Title) │
│ - Rotten Tomatoes (critics/aud│         │ - Rating (score & votes)     │
│ - Metacritic                  │         │ - Anti-ban protection        │
│ - Letterboxd                  │         │ - Dynamic Confidence Scoring │
│ - TMDb                        │         └──────────────────────────────┘
└───────────────────────────────┘
```

### Key Design Principles

1. **Information Hiding**: The client never sees upstream API keys, scraping endpoints, or provider payloads.
2. **Aggressive Caching**: Ratings are slow-changing data. Fresh data is cached for 7 to 30 days based on the release year.
3. **Graceful Degradation**: Failures from one provider (e.g. Douban block or timeout) do not invalidate successful ratings from others (e.g. MDBList).
4. **Permanent ID Mappings**: Resolved mappings between IMDb, TMDb, TVDb, and Douban subject IDs are saved permanently in Cloudflare D1.
5. **Circuit Breaker**: Repeated upstream failures trip a circuit breaker, serving cached/stale data without hanging client requests.

---

## 2. API Contract & Endpoints

All public API endpoints are versioned under `/v1/`.

### 2.1 Public Endpoints

#### `GET /health`
Liveness probe. Does not make upstream provider calls.
```bash
curl "https://<domain>/health"
```
**Response (200 OK):**
```json
{
  "status": "ok"
}
```

#### `GET /v1/ratings`
Fetch unified ratings for a media title by ID.
Supported query parameters:
- `imdb` (e.g. `tt0903747`): Preferred canonical identifier.
- `tmdb` (e.g. `1396`): TMDb positive integer ID.
- `tvdb` (e.g. `81189`): TVDb positive integer ID.
- `type` (`movie` or `tv`): Required when querying by TMDb or TVDb ID without IMDb ID.

When `APP_API_KEY` is configured, this endpoint requires `Authorization: Bearer
<APP_API_KEY>`. If it is unset, the endpoint remains public for local
development. Refresh and admin endpoints always require the secret.

```bash
# Query by IMDb ID
curl "https://<domain>/v1/ratings?imdb=tt0903747"

# Query by TMDb ID & media type
curl "https://<domain>/v1/ratings?tmdb=1396&type=tv"
curl "https://<domain>/v1/ratings?tmdb=278&type=movie"
```

**Response (200 OK):**
```json
{
  "media": {
    "type": "tv",
    "title": "Breaking Bad",
    "year": 2008
  },
  "ids": {
    "imdb": "tt0903747",
    "tmdb": 1396,
    "tvdb": 81189,
    "douban": "2373195"
  },
  "ratings": {
    "imdb": {
      "score": 9.5,
      "votes": 2300000
    },
    "rottenTomatoes": {
      "critics": 96,
      "audience": 97
    },
    "metacritic": {
      "score": 87
    },
    "letterboxd": {
      "score": 4.5
    },
    "tmdb": {
      "score": 8.9,
      "votes": 15000
    },
    "douban": {
      "score": 9.2,
      "votes": 390812,
      "url": "https://movie.douban.com/subject/2373195/"
    }
  },
  "meta": {
    "cached": true,
    "stale": false,
    "updatedAt": "2026-09-14T03:45:18.478Z"
  }
}
```

---

### 2.2 Protected Administrative Endpoints

Requires `Authorization: Bearer <APP_API_KEY>`.

#### `POST /v1/ratings/refresh`
Forces an upstream re-fetch, bypassing fresh cache.
```bash
curl -X POST "https://<domain>/v1/ratings/refresh" \
  -H "Authorization: Bearer <APP_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"imdb": "tt0903747"}'
```

#### `PUT /v1/admin/identity/douban`
Manually bind an IMDb / TMDb ID to a Douban subject ID with maximum confidence (1.0).
```bash
curl -X PUT "https://<domain>/v1/admin/identity/douban" \
  -H "Authorization: Bearer <APP_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "imdb": "tt0903747",
    "douban": "2373195"
  }'
```

#### `DELETE /v1/admin/cache`
Invalidate cached ratings for an identity.
```bash
curl -X DELETE "https://<domain>/v1/admin/cache" \
  -H "Authorization: Bearer <APP_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"imdb": "tt0903747"}'
```

---

## 3. Cache Strategy & Lifecycle

The system utilizes a **two-layer cache** with **Stale-While-Revalidate (SWR)** and **Negative Caching**:

```text
Incoming Request
       │
       ▼
   [L1 Cache] ─────────────── Hit ───────────────► Return immediately (cached: true, stale: false)
       │ Miss
       ▼
   [D1 Cache] ────────────── Fresh ──────────────► Populate L1 ──► Return (cached: true, stale: false)
       │
       ├───────────────────── Stale ──────────────► Return Stale immediately (cached: true, stale: true)
       │                                           └─► Trigger background refresh via ctx.waitUntil()
       ▼ Miss
[Fetch Upstream Providers]
       │
       ├─► Success: Persist to D1, populate L1, return 200 (cached: false)
       ├─► Upstream Error + Stale Exists: Fallback to stale D1 data, return 200 (stale: true)
       └─► All Providers Fail + No Cache: Return 502 Bad Gateway
```

### Dynamic TTL Policies
- **MDBList Ratings**:
  - Recent media (<= 2 years old): **7 days**
  - Catalog media (> 2 years and < 10 years old): **14 days**
  - Classic media (>= 10 years old): **30 days**
  - 404 Not Found (Negative Cache): **6 hours**
- **Douban Ratings**:
  - Recent media: **7 days**
  - Catalog media: **14 days**
  - Classic media: **30 days**
  - Unresolved / No match (Negative Cache): **24 hours**
- **L1 Cloudflare Cache API**: **60 seconds** to absorb rapid burst queries across Worker isolates.
- **Request Deduplication**: In-flight promise map collapses multiple concurrent requests for the same item into a single upstream call.

---

## 4. Douban Matching Strategy

Douban lacks an official public API for international cross-referencing. To achieve high precision and prevent false matches:

### Resolution Hierarchy

1. **Level 1 — Stored Identity**:
   Queries Cloudflare D1 `media_identity` for `douban_id`. If already mapped, skips search entirely and directly scrapes the subject page.
2. **Level 2 — IMDb Direct Search**:
   Queries Douban mobile search with the IMDb ID (`https://m.douban.com/search/?query=tt...`). A result is accepted only when the response explicitly associates that subject with the exact IMDb ID; an arbitrary first result is rejected. Otherwise title/year scoring is required.
3. **Level 3 — Title Search & Multi-factor Scoring**:
   Queries Douban suggest / search APIs with original title and localized title, evaluating all candidates against the target media.

### Scoring Algorithm (Section 15)

```text
Original title exact match:   +0.45
Localized title exact match:  +0.35
Year exact match:             +0.20 (±1 year: +0.10)
Media type match:             +0.10
IMDb ID match:                +1.00
Score clamped between:        0.00 – 1.00
```

- **Threshold $\ge 0.85$**: Accepted and persisted to D1.
- **Score $0.70 - 0.84$**: Kept internal, not exposed to client (Douban score returned as `null`).
- **Score $< 0.70$**: Unresolved. Negative cached for 24 hours.

> **Rule**: False matching is strictly worse than returning no Douban score.

---

## 5. Local Development

### Prerequisites
- Node.js $\ge 18$
- npm $\ge 9$
- Cloudflare Wrangler CLI

### Quick Start

1. **Install dependencies**:
   ```bash
   npm install
   ```

2. **Configure environment variables**:
   ```bash
   cp .dev.vars.example .dev.vars
   ```
   Edit `.dev.vars` with your credentials:
   ```dotenv
   MDBLIST_API_KEY=your_mdblist_api_key_here
   APP_API_KEY=test-key
   ENVIRONMENT=development
   DOUBAN_ENABLED=true
   MDBLIST_ENABLED=true
   ```

3. **Apply local D1 database migrations**:
   ```bash
   npm run d1:migrate:local
   ```

4. **Start local development server**:
   ```bash
   npm run dev
   ```
   The local worker starts on `http://localhost:8787`.

5. **Run automated test suite**:
   ```bash
   npm test
   ```

The 60 requests/minute limiter uses Cloudflare's `CF-Connecting-IP` and is
per-isolate in v1. It does not trust `X-Forwarded-For`; use a KV or Durable
Object coordination layer if a strict cross-isolate limit is required.

6. **Check TypeScript typing**:
   ```bash
   npm run build
   ```

---

## 6. Cloudflare Deployment

### 1. Create Remote D1 Database
```bash
npx wrangler d1 create ratings-db
```
Copy the `database_id` output and replace `REPLACE_WITH_D1_DATABASE_ID` in
`wrangler.toml`:
```toml
[[d1_databases]]
binding = "DB"
database_name = "ratings-db"
  database_id = "<your-database-id>"
migrations_dir = "migrations"
```

### 2. Apply Remote Migrations
```bash
npm run d1:migrate:remote
```

### 3. Set Production Secrets
```bash
npx wrangler secret put MDBLIST_API_KEY
npx wrangler secret put APP_API_KEY
```

### 4. Deploy Worker
```bash
npm run deploy
```

---

## 7. Verification Checklist

- [x] TypeScript compile passes (`npm run build`)
- [x] Unit & integration tests pass (`npm test`)
- [x] D1 database migrations apply cleanly (`npm run d1:migrate:local`)
- [x] Worker starts locally (`npm run dev`)
- [x] `/health` responds with `200 {"status":"ok"}`
- [x] `/v1/ratings?imdb=...` accepts IMDb ID and normalizes schema
- [x] Second identical request hits cache (`meta.cached: true`)
- [x] Douban ID persists in D1 `media_identity`
- [x] Provider timeout and circuit breaker handled
- [x] Partial provider response works (e.g. Douban only or MDBList only)
- [x] Protected routes reject unauthorized requests with 401
- [x] Rate limiting enforces 60 requests/minute/IP with 429
- [x] Secrets are masked in structured logs
