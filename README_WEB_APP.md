# Content Marketing Platform - Web UI + Auth

## Files Created

### Database & API
- `api/migrations/001_initial_schema.sql` - Database schema (users, sessions, products, content_items, analytics_tokens)
- `api/db.js` - PostgreSQL connection pool
- `api/middleware/auth.js` - Session-based auth middleware
- `api/routes/auth.js` - Register, login, logout, me endpoints
- `api/routes/briefs.js` - Brief enrichment endpoint
- `api/routes/content.js` - Content CRUD, approve/reject, variant editing
- `api/routes/calendar.js` - 30-day calendar view, draft generation
- `api/routes/analytics.js` - Scoreboard, analytics token generation/rotation, event ingestion
- `api/routes/settings.js` - Product settings (publishing, timezone, integrations)
- `api/server.js` - Express server with all routes
- `api/scripts/migrate.js` - Migration runner
- `api/test/auth.test.js` - Test skeleton

### Next.js Web App
- `web/app/login/page.tsx` - Login page
- `web/app/register/page.tsx` - Registration (creates product + user)
- `web/app/onboarding/page.tsx` - 7-step onboarding wizard
- `web/app/content/page.tsx` - Content list with status filters
- `web/app/content/[id]/page.tsx` - Content detail with variants, warnings, edit, approve/reject
- `web/app/calendar/page.tsx` - 30-day calendar view
- `web/app/analytics/page.tsx` - Scoreboard, token generation, webhook snippets
- `web/app/settings/page.tsx` - Settings (publishing, timezone, integrations)
- `web/lib/api.ts` - API client with automatic cookie handling
- `web/middleware.ts` - Next.js middleware for route protection

## Architecture Decisions

**Auth Choice**: Cookie-based sessions (httpOnly, secure) - chosen for security (XSS protection) and simplicity. No NextAuth to reduce dependencies.

**Email Uniqueness**: Globally unique email - simpler for auth, can add product_id later if needed for multi-email-per-product.

**Monorepo Structure**: Added `/web` and `/api` to existing repo - least risky, keeps everything together.

**Secrets Handling**: 
- Buffer tokens stored encrypted (placeholder - implement encryption)
- Analytics tokens hashed (SHA256) before storage
- API keys never exposed in UI
- Settings endpoint redacts sensitive fields

## Setup Commands

```bash
# 1. Install API dependencies
cd api
npm install

# 2. Set up database
createdb content_db
export DATABASE_URL=postgresql://user:password@localhost:5432/content_db
npm run migrate

# 3. Install Web dependencies
cd ../web
npm install

# 4. Start API server
cd ../api
npm run dev  # Runs on port 3001

# 5. Start Web server (in new terminal)
cd web
npm run dev  # Runs on port 3000
```

## Testing

```bash
# API tests
cd api
npm test

# Type check web app
cd web
npm run type-check
```

## Key Features Implemented

✅ Multi-tenant (user belongs to product)
✅ Session-based auth with httpOnly cookies
✅ Onboarding wizard (7 steps)
✅ Content management with variants, warnings, editing
✅ Calendar view with draft generation
✅ Analytics scoreboard + token generation
✅ Settings with integrations (Slack, Buffer)
✅ Webhook snippet generator
✅ Never exposes secrets in UI
✅ Audit logging for content edits

## Notes

- Buffer token encryption is placeholder - implement proper encryption in production
- Analytics events storage is simplified - add events table for production
- Content generation is placeholder - integrate with actual AI/content generation service
- Brief enrichment is placeholder - implement actual website scraping/enrichment

