# TinaCMS GitHub Authentication Setup

## Issue
"Missing client ID" error when trying to authenticate with GitHub through TinaCMS.

## Solution

### 1. Create a GitHub OAuth App

1. Go to GitHub Settings → Developer settings → OAuth Apps
2. Click "New OAuth App"
3. Fill in:
   - **Application name**: Your app name (e.g., "CortexIDE Content CMS")
   - **Homepage URL**: Your app URL (e.g., `http://localhost:3000` for dev)
   - **Authorization callback URL**: `http://localhost:3000/api/tina/callback` (for dev) or your production URL
4. Click "Register application"
5. Copy the **Client ID** (you'll need this)
6. Generate a **Client Secret** and copy it

### 2. Install TinaCMS

```bash
cd web
npm install tinacms @tinacms/auth
```

### 3. Configure Environment Variables

Create a `.env.local` file in the `web/` directory:

```env
NEXT_PUBLIC_TINA_CLIENT_ID=your_github_client_id_here
TINA_CLIENT_SECRET=your_github_client_secret_here
NEXT_PUBLIC_TINA_BRANCH=main
```

### 4. Configure TinaCMS

You'll need to create a TinaCMS configuration file. The exact setup depends on your TinaCMS version and structure.

For Next.js App Router, you typically need:
- A `tina/config.ts` file
- API routes for authentication callbacks
- TinaCMS provider in your layout

### 5. Example Configuration

If you're using TinaCMS with Next.js, you might need something like:

```typescript
// tina/config.ts
import { defineConfig } from 'tinacms';

export default defineConfig({
  clientId: process.env.NEXT_PUBLIC_TINA_CLIENT_ID!,
  branch: process.env.NEXT_PUBLIC_TINA_BRANCH || 'main',
  // ... other config
});
```

## Quick Fix

If you just need to get past the error temporarily, you can set a placeholder client ID:

```env
NEXT_PUBLIC_TINA_CLIENT_ID=placeholder
```

But you'll need a real GitHub OAuth App for actual authentication to work.
