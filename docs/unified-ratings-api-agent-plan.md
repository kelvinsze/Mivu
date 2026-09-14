# Unified Ratings API — Agent Implementation Plan

## 1. Objective

Build a self-hosted unified media ratings API for an iOS/macOS/tvOS media player.

The client application must only communicate with our own backend and must not directly depend on MDBList, Douban, Rotten Tomatoes, IMDb, Letterboxd, Metacritic, or other external rating providers.

Primary goals:

- Reduce client-side maintenance.
- Reduce MDBList API usage through server-side caching.
- Aggregate multiple rating sources behind one stable API contract.
- Add Douban ratings through server-side lookup/scraping.
- Maintain reusable mappings between IMDb / TMDb / TVDb / Douban IDs.
- Allow upstream providers to be changed later without requiring an App Store update.
- Fail gracefully if one rating source is unavailable.

Target stack:

- Cloudflare Workers
- Cloudflare D1
- Cloudflare Cache API and/or KV
- TypeScript
- Hono recommended, but native Workers routing is acceptable
- MDBList as the primary third-party rating aggregator
- Douban as a separately resolved source

---

# 2. Architecture

```text
iOS / macOS / tvOS
        |
        | HTTPS
        v
+------------------------+
| Unified Ratings API    |
| Cloudflare Worker      |
+------------------------+
        |
        +----------------------+
        |                      |
        v                      v
+---------------+       +---------------+
| Cache         |       | D1 Database   |
| Cache API/KV  |       | ID Mapping    |
+---------------+       | Ratings Cache |
        |               +---------------+
        |
        | cache miss / stale
        v
+---------------------------+
| Provider Adapters         |
+---------------------------+
       |              |
       v              v
+-------------+   +-------------+
| MDBList API |   | Douban      |
| IMDb        |   | Resolver /  |
| RT          |   | Scraper     |
| Metacritic  |   +-------------+
| Letterboxd  |
+-------------+
```

The client must never know:

- MDBList API keys
- Douban scraping implementation
- provider-specific payload structures
- provider URLs
- cache policy

---

# 3. Public API Contract

Initial version:

```text
GET /v1/ratings
```

Supported identifiers:

```text
GET /v1/ratings?imdb=tt0903747
GET /v1/ratings?tmdb=1396&type=tv
GET /v1/ratings?tmdb=278&type=movie
```

At least one supported identifier must be provided.

Preferred lookup priority:

```text
IMDb ID
→ TMDb ID
→ TVDb ID
```

IMDb should be treated as the preferred canonical lookup ID whenever available.

---

# 4. Response Schema

Return our own normalized schema.

Do not expose raw MDBList or Douban response structures.

Example:

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
    "douban": "2131459"
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
      "score": 9.5,
      "votes": 700000,
      "url": "https://movie.douban.com/subject/2131459/"
    }
  },
  "meta": {
    "cached": true,
    "stale": false,
    "updatedAt": "2026-09-14T03:00:00Z"
  }
}
```

Unknown values should be omitted or set to `null`.

Do not fabricate missing values.

---

# 5. HTTP Status Codes

Use predictable status semantics.

## 200

At least one valid rating source returned data.

Partial results are acceptable.

Example:

```json
{
  "ratings": {
    "imdb": {
      "score": 8.7
    },
    "douban": null
  }
}
```

## 400

Invalid request.

Examples:

- no ID provided
- malformed IMDb ID
- unsupported media type

## 404

Media cannot be resolved by any provider.

## 429

Client rate limit exceeded.

## 500

Unexpected internal application failure.

## 502

All required upstream providers failed and no cached result exists.

---

# 6. Database Schema

Use Cloudflare D1.

Create migrations.

## 6.1 media_identity

```sql
CREATE TABLE media_identity (
    id INTEGER PRIMARY KEY AUTOINCREMENT,

    media_type TEXT NOT NULL,

    imdb_id TEXT,
    tmdb_id INTEGER,
    tvdb_id INTEGER,
    douban_id TEXT,

    title TEXT,
    original_title TEXT,
    year INTEGER,

    douban_match_confidence REAL,

    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_identity_imdb
ON media_identity(imdb_id)
WHERE imdb_id IS NOT NULL;

CREATE INDEX idx_identity_tmdb
ON media_identity(tmdb_id, media_type);

CREATE INDEX idx_identity_douban
ON media_identity(douban_id);
```

---

# 7. Ratings Cache Table

```sql
CREATE TABLE ratings_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,

    identity_id INTEGER NOT NULL,

    provider TEXT NOT NULL,

    payload TEXT NOT NULL,

    fetched_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,

    FOREIGN KEY(identity_id)
        REFERENCES media_identity(id)
        ON DELETE CASCADE
);

CREATE UNIQUE INDEX idx_rating_provider
ON ratings_cache(identity_id, provider);
```

`provider` examples:

```text
mdblist
douban
```

Store normalized provider results, not necessarily raw responses.

---

# 8. Provider Abstraction

Implement provider adapters.

Recommended structure:

```text
src/
  providers/
    mdblist.ts
    douban.ts
    types.ts

  services/
    ratings.ts
    identity.ts
    cache.ts

  routes/
    ratings.ts

  db/
    identity.ts
    ratings-cache.ts

  utils/
    normalize.ts
    validation.ts
```

Define an interface similar to:

```ts
interface RatingProvider {
  fetchRatings(input: MediaIdentity): Promise<ProviderResult>;
}
```

Provider failures must remain isolated.

A Douban failure must not cause MDBList data to fail.

---

# 9. MDBList Integration

Environment secret:

```text
MDBLIST_API_KEY
```

Never expose the key to the client.

Use IMDb ID whenever possible.

Flow:

```text
IMDb ID
↓
MDBList
↓
normalize
↓
cache
```

Normalize MDBList ratings into our schema.

Example mapping:

```text
IMDb           → ratings.imdb
RottenTomatoes → ratings.rottenTomatoes
Metacritic     → ratings.metacritic
Letterboxd     → ratings.letterboxd
TMDb           → ratings.tmdb
```

Do not return unknown provider fields automatically.

New fields must be added intentionally to our API schema.

---

# 10. MDBList Cache Policy

Default TTL:

```text
IMDb             7 days
Rotten Tomatoes  7 days
Metacritic       7 days
Letterboxd       3 days
TMDb             3 days
```

For simplicity in v1, the MDBList aggregate payload may use a single TTL:

```text
7 days
```

Optimization later:

If media release year is older than 2 years:

```text
TTL = 14 days
```

If older than 10 years:

```text
TTL = 30 days
```

Ratings do not require real-time precision.

---

# 11. Stale-While-Revalidate

Implement stale cache support.

Example:

```text
fresh TTL: 7 days
stale TTL: 30 days
```

Behavior:

```text
cache age < 7 days
→ return immediately

7 days <= cache age < 30 days
→ return stale result immediately
→ attempt refresh

cache age >= 30 days
→ fetch upstream before responding
```

If Workers runtime constraints make true background refresh inconvenient, returning stale data when upstream fails is more important than strict SWR semantics.

Response metadata:

```json
{
  "meta": {
    "cached": true,
    "stale": true
  }
}
```

---

# 12. Douban Integration

Do not call Douban directly from the Apple client.

All Douban access must happen server-side.

Responsibilities:

1. resolve Douban subject ID
2. fetch rating
3. normalize result
4. cache result
5. store ID mapping permanently

Desired normalized result:

```ts
interface DoubanRating {
  score: number | null;
  votes: number | null;
  subjectId: string;
  url: string;
}
```

---

# 13. Douban ID Resolution

Douban ID lookup is expected to be the most fragile part of the system.

Avoid searching Douban every time.

Once a reliable match exists:

```text
IMDb/TMDb ID → Douban ID
```

store it permanently in `media_identity`.

Future requests must reuse the stored mapping.

---

# 14. Douban Matching Strategy

Use the following order.

## Level 1 — Existing mapping

Check D1.

```text
IMDb ID → media_identity.douban_id
```

If present:

```text
do not search again
```

---

## Level 2 — External identifier if available

If a reliable endpoint or source allows mapping IMDb → Douban directly, use it.

This should remain behind an adapter so it can be replaced later.

---

## Level 3 — Search

Search using:

```text
title
original title
year
media type
```

Example query conceptually:

```text
Breaking Bad 2008
```

Collect candidate results.

---

# 15. Douban Candidate Matching

Calculate confidence.

Suggested scoring:

```text
exact original title match     +0.45
exact localized title match    +0.35
year exact match               +0.20
IMDb identifier match          +1.00
media type match               +0.10
```

Clamp result to:

```text
0.0 – 1.0
```

Automatic acceptance threshold:

```text
>= 0.85
```

Possible result:

```text
0.70 – 0.84
```

Store candidate only if useful, but do not expose a potentially incorrect Douban rating.

Below:

```text
< 0.70
```

treat as unresolved.

False matching is worse than returning no Douban score.

---

# 16. Douban Cache

Suggested:

```text
fresh TTL: 7 days
stale TTL: 30 days
```

For old movies:

```text
fresh TTL: 14–30 days
```

Do not repeatedly access Douban for unchanged media.

---

# 17. Douban Request Protection

Implement conservative upstream behavior.

Requirements:

- realistic browser User-Agent
- timeout
- low concurrency
- retries limited to 1
- no aggressive crawling
- cache every successful result
- do not scrape the same subject repeatedly

Suggested timeout:

```text
5 seconds
```

Suggested global per-instance concurrency:

```text
2–4 Douban requests
```

If Douban blocks or returns unexpected HTML:

```text
return other ratings
do not fail entire endpoint
```

---

# 18. Cache Layers

Use two layers.

```text
Layer 1:
Cloudflare Cache API / KV

Layer 2:
D1 persistent cache
```

Request:

```text
GET /v1/ratings?imdb=tt0903747
```

Cache key:

```text
ratings:v1:imdb:tt0903747
```

or canonical:

```text
ratings:v1:<identity_id>
```

Recommended process:

```text
L1 hit
→ return

L1 miss
→ D1

D1 fresh
→ populate L1
→ return

D1 stale
→ return stale / refresh

D1 miss
→ providers
```

---

# 19. Request Deduplication

Prevent multiple simultaneous client requests from generating duplicate upstream calls.

Example:

```text
20 clients request same movie simultaneously
```

Should result in approximately:

```text
1 MDBList request
1 Douban request
```

Use an in-process promise map where practical:

```ts
Map<string, Promise<RatingsResult>>
```

For cross-instance locking, do not over-engineer v1.

Cloudflare Durable Objects may be added later if request volume requires strict distributed request collapsing.

---

# 20. Client Rate Limiting

Protect the public API.

Example:

```text
60 requests / minute / IP
```

Authenticated users may receive higher limits later.

Return:

```text
429 Too Many Requests
```

Do not use client rate limiting as a substitute for provider caching.

---

# 21. Authentication

For private/test deployment, support:

```text
Authorization: Bearer <APP_API_KEY>
```

Environment:

```text
APP_API_KEY
```

For a public App Store release, do not embed a permanent privileged secret and assume it is secure.

Initial implementation may use an application token only as lightweight abuse protection.

Architecture should allow migration later to:

- signed requests
- anonymous session token
- App Attest
- DeviceCheck
- authenticated user accounts

Authentication must not be tightly coupled to ratings logic.

---

# 22. Canonical Identity Resolution

Implement:

```ts
resolveIdentity(input)
```

Input:

```ts
{
  imdb?: string;
  tmdb?: number;
  tvdb?: number;
  type?: "movie" | "tv";
}
```

Expected output:

```ts
{
  identityId: number;
  imdb?: string;
  tmdb?: number;
  tvdb?: number;
  douban?: string;
  title?: string;
  year?: number;
  type: "movie" | "tv";
}
```

If only TMDb ID is supplied, use available metadata/provider data to discover IMDb ID where feasible, then persist it.

Avoid requiring clients to always know every external ID.

---

# 23. API Versioning

All public routes must include version.

Use:

```text
/v1/
```

Never expose an unversioned production endpoint such as:

```text
/ratings
```

Future incompatible schema changes should use:

```text
/v2/
```

---

# 24. API Error Schema

Normalize errors.

Example:

```json
{
  "error": {
    "code": "INVALID_IMDB_ID",
    "message": "IMDb ID must match tt followed by digits."
  }
}
```

Internal provider errors must not expose:

- API keys
- Cloudflare secrets
- stack traces
- full upstream responses containing sensitive data

---

# 25. Validation

IMDb:

```regex
^tt\d{5,10}$
```

TMDb:

```text
positive integer
```

Media type:

```text
movie
tv
```

Reject invalid inputs before querying any provider.

---

# 26. Observability

Implement structured logs.

Example:

```json
{
  "event": "ratings_request",
  "identity": "tt0903747",
  "cache": "hit",
  "providers": {
    "mdblist": "cached",
    "douban": "fresh"
  },
  "durationMs": 34
}
```

Never log API keys.

Useful metrics:

```text
total requests
L1 cache hit rate
D1 cache hit rate
MDBList calls/day
Douban calls/day
MDBList failures
Douban failures
Douban match confidence
average response latency
```

---

# 27. Provider Circuit Breaker

Simple failure protection is recommended.

If Douban repeatedly fails:

```text
5 failures within short interval
```

temporarily skip Douban requests.

Continue serving:

```text
MDBList + cached Douban
```

Likewise, if MDBList is unavailable:

```text
serve cached MDBList values if available
```

The ratings endpoint should degrade progressively rather than fail completely.

---

# 28. Environment Variables

Example:

```text
MDBLIST_API_KEY=
APP_API_KEY=

ENVIRONMENT=development

DOUBAN_ENABLED=true
MDBLIST_ENABLED=true
```

Cloudflare bindings:

```text
DB
RATINGS_KV
```

Never commit secrets.

Provide:

```text
.dev.vars.example
```

Example:

```dotenv
MDBLIST_API_KEY=
APP_API_KEY=test-key
DOUBAN_ENABLED=true
MDBLIST_ENABLED=true
```

---

# 29. Suggested Worker Project

```text
ratings-api/
│
├── src/
│   ├── index.ts
│   │
│   ├── routes/
│   │   ├── ratings.ts
│   │   └── health.ts
│   │
│   ├── services/
│   │   ├── ratings.ts
│   │   ├── identity.ts
│   │   └── cache.ts
│   │
│   ├── providers/
│   │   ├── types.ts
│   │   ├── mdblist.ts
│   │   └── douban.ts
│   │
│   ├── db/
│   │   ├── identity.ts
│   │   └── ratings-cache.ts
│   │
│   └── utils/
│       ├── validation.ts
│       ├── response.ts
│       └── logger.ts
│
├── migrations/
│   └── 0001_initial.sql
│
├── tests/
│   ├── ratings.test.ts
│   ├── identity.test.ts
│   ├── mdblist.test.ts
│   └── douban.test.ts
│
├── wrangler.toml
├── package.json
├── tsconfig.json
├── .dev.vars.example
└── README.md
```

---

# 30. Health Endpoint

Implement:

```text
GET /health
```

Response:

```json
{
  "status": "ok"
}
```

Do not perform MDBList or Douban requests for every health check.

Optional:

```text
GET /health/providers
```

may be available only in protected/debug environments.

---

# 31. Force Refresh

Add protected endpoint:

```text
POST /v1/ratings/refresh
```

Body:

```json
{
  "imdb": "tt0903747"
}
```

This endpoint must require authorization.

Purpose:

- debugging
- manual refresh
- correcting stale provider information

Do not expose unrestricted cache bypass to the public client.

---

# 32. Manual Douban Mapping

Provide a protected administrative endpoint.

Example:

```text
PUT /v1/admin/identity/douban
```

Body:

```json
{
  "imdb": "tt0903747",
  "douban": "2131459"
}
```

Reason:

Automated matching will never be perfect.

Manual correction must be possible without modifying the database manually.

Store manually supplied mappings with maximum confidence.

Optional schema extension:

```sql
douban_match_source TEXT
```

Values:

```text
auto
manual
external
```

---

# 33. Negative Caching

If Douban lookup finds no reliable match, cache that failure temporarily.

Example:

```text
douban:no-match TTL = 24 hours
```

Otherwise every client request may repeatedly perform the same failed search.

Likewise:

```text
MDBList 404
```

may be cached for a shorter period such as:

```text
6 hours
```

---

# 34. Upstream Timeouts

Do not allow one provider to hold the full request open indefinitely.

Recommended:

```text
MDBList: 5 seconds
Douban: 5 seconds
```

Potential execution:

```ts
AbortSignal.timeout(5000)
```

The endpoint should combine all available successful provider results.

---

# 35. Parallel Provider Loading

Once identity resolution is complete:

```text
MDBList
Douban
```

should be fetched in parallel when both require refresh.

Use:

```ts
Promise.allSettled()
```

not:

```ts
Promise.all()
```

A failure from one provider must not reject successful results from another.

---

# 36. Security

Required:

- HTTPS only
- secrets stored in Worker environment
- no upstream credentials returned
- validate all parameters
- parameterized D1 queries
- rate limiting
- administrative routes protected
- CORS restricted to required use cases where practical

Do not implement arbitrary proxy endpoints.

For example, never support:

```text
/proxy?url=https://...
```

---

# 37. Client Contract

The Apple client should implement only one ratings service.

Example Swift conceptual API:

```swift
func ratings(
    imdbID: String?,
    tmdbID: Int?,
    type: MediaType
) async throws -> MediaRatings
```

The client should not include:

```text
MDBListSDK
Douban scraper
RT scraper
provider-specific parsing
provider keys
```

All provider implementation belongs on the server.

---

# 38. Client Caching

The App may additionally cache results locally.

Recommended client TTL:

```text
24 hours
```

Server cache remains authoritative.

Purpose of client cache:

- instant UI rendering
- offline viewing
- eliminate unnecessary network requests

Recommended behavior:

```text
show local cached rating immediately
→ refresh from API in background
→ update UI only if value changed
```

---

# 39. Preferred Display Data

Initial supported sources:

```text
IMDb
Rotten Tomatoes Critics
Rotten Tomatoes Audience
Metacritic
Letterboxd
Douban
TMDb
```

Do not require every source.

Example UI should tolerate:

```text
IMDb      8.7
豆瓣       9.4
RT        unavailable
MC        unavailable
```

---

# 40. Testing

Use mocked providers.

Do not rely on real MDBList or Douban in unit tests.

Required test cases:

### Request validation

```text
missing ID
invalid IMDb
invalid type
```

### Cache

```text
L1 cache hit
D1 fresh hit
D1 stale hit
complete miss
```

### MDBList

```text
successful response
404
429
timeout
invalid JSON
```

### Douban

```text
known ID
successful scrape
no rating
blocked request
HTML changed
timeout
```

### Aggregation

```text
both providers succeed
MDBList succeeds / Douban fails
Douban succeeds / MDBList fails
both fail but stale cache exists
both fail and no cache exists
```

### Matching

```text
exact title + year
same title different year
localized title
ambiguous results
confidence below threshold
```

---

# 41. Acceptance Criteria

The implementation is considered complete when:

1. The service deploys successfully to Cloudflare Workers.

2. The following works:

```bash
curl \
  -H "Authorization: Bearer TEST_KEY" \
  "https://<domain>/v1/ratings?imdb=tt0903747"
```

3. Response follows our normalized schema.

4. A repeated request for the same media does not call MDBList again while cache is fresh.

5. A repeated request for a known Douban item does not perform title search again.

6. Douban outage does not prevent MDBList ratings from being returned.

7. MDBList outage does not prevent cached data from being returned.

8. Secrets never appear in responses or logs.

9. D1 stores ID mappings.

10. Unit tests cover provider failures and caching.

---

# 42. Implementation Phases

## Phase 1 — Foundation

Implement:

```text
Cloudflare Worker
Hono
D1
/v1/ratings
/health
validation
response schema
```

No Douban yet.

---

## Phase 2 — MDBList

Implement:

```text
MDBList adapter
normalization
D1 cache
L1 cache
TTL
```

Validate that repeated requests do not consume additional MDBList quota.

---

## Phase 3 — Identity Layer

Implement:

```text
media_identity
IMDb/TMDb mapping
canonical identity
```

The ratings service must operate on identity records instead of arbitrary request IDs.

---

## Phase 4 — Douban

Implement:

```text
Douban subject lookup
candidate matching
rating extraction
Douban ID persistence
negative cache
```

False matches must be prioritized over coverage.

If uncertain:

```text
return null
```

---

## Phase 5 — Resilience

Implement:

```text
stale cache
Promise.allSettled
timeouts
rate limiting
structured logging
provider circuit breaker
```

---

## Phase 6 — Admin

Implement:

```text
force refresh
manual Douban mapping
cache inspection if useful
```

---

# 43. Non-Goals for V1

Do not implement unless necessary:

- user accounts
- payment/subscriptions
- recommendation engine
- watch history
- Emby server integration inside backend
- Jellyfin integration
- Plex integration
- bulk web crawler
- scheduled crawling of entire MDBList/Douban catalogs
- distributed Durable Object locking
- complex analytics dashboard

Keep v1 narrowly focused on rating aggregation.

---

# 44. Important Engineering Rules

The agent must follow these rules.

### Rule 1

The Apple client must never directly call MDBList or Douban.

### Rule 2

Provider schemas must never become the public API schema.

### Rule 3

Cache aggressively.

Ratings are slow-changing data.

### Rule 4

Persist external ID mappings.

Do not repeatedly rediscover Douban IDs.

### Rule 5

Return partial data.

One failed provider must not invalidate the entire response.

### Rule 6

Never guess a Douban match.

Missing is better than incorrect.

### Rule 7

Do not make the application depend on scraping HTML selectors scattered throughout the codebase.

All parsing must live inside:

```text
providers/douban.ts
```

### Rule 8

Use interfaces and adapters so providers can be replaced later.

For example:

```text
MDBList
→ another aggregator
```

must not require changing route handlers or client code.

---

# 45. Future Extensions

The architecture should permit adding:

```text
Bangumi
AniList
MyAnimeList
Trakt
TMDb Watch Providers
JustWatch-compatible provider
Kinopoisk
MyDramaList
```

Example future normalized schema:

```json
{
  "ratings": {
    "imdb": {},
    "douban": {},
    "bangumi": {},
    "anilist": {}
  }
}
```

No redesign should be required.

---

# 46. Deliverables Required From Agent

The coding agent must deliver:

```text
1. Complete source code
2. D1 migrations
3. wrangler configuration
4. .dev.vars.example
5. automated tests
6. README
7. local development instructions
8. Cloudflare deployment instructions
9. API request/response examples
10. explanation of cache strategy
11. explanation of Douban matching strategy
```

README must include:

```bash
npm install
npm run dev
npm test
npm run deploy
```

or equivalent commands matching the chosen package manager.

---

# 47. Agent Final Validation

Before considering the task complete, verify:

```text
[ ] TypeScript compile passes
[ ] Tests pass
[ ] Worker starts locally
[ ] D1 migrations apply
[ ] /health responds
[ ] /v1/ratings accepts IMDb ID
[ ] MDBList response normalizes correctly
[ ] second identical request hits cache
[ ] Douban ID persists
[ ] provider timeout is handled
[ ] partial provider response works
[ ] secrets are not exposed
[ ] README reproduces deployment
```

---

# 48. Recommended Initial Priority

Prioritize correctness and maintainability in this order:

```text
1. Stable public API contract
2. Caching
3. MDBList integration
4. Identity mapping
5. Douban matching correctness
6. Failure isolation
7. Optimization
```

Do not optimize Douban coverage by accepting ambiguous matches.

The most important design invariant is:

```text
Client → Our API → Provider adapters
```

The client must remain independent of all upstream rating providers.
