-- Products table (tenants)
CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  website_url VARCHAR(500),
  category VARCHAR(100),
  brand_voice TEXT,
  icp_role VARCHAR(255),
  pain_points TEXT[],
  differentiators TEXT[],
  offer TEXT,
  pricing_model VARCHAR(100),
  proof_assets TEXT[],
  publishing_enabled BOOLEAN DEFAULT false,
  timezone VARCHAR(50) DEFAULT 'UTC',
  slack_webhook_url VARCHAR(500),
  buffer_access_token TEXT, -- encrypted in app
  buffer_profiles JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Users table
-- Email is globally unique (simpler for auth, can add product_id later if needed)
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  email VARCHAR(255) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  last_login_at TIMESTAMP
);

CREATE INDEX idx_users_product_id ON users(product_id);
CREATE INDEX idx_users_email ON users(email);

-- Sessions table
CREATE TABLE IF NOT EXISTS sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  token_hash VARCHAR(255) NOT NULL UNIQUE,
  expires_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  revoked_at TIMESTAMP
);

CREATE INDEX idx_sessions_user_id ON sessions(user_id);
CREATE INDEX idx_sessions_product_id ON sessions(product_id);
CREATE INDEX idx_sessions_token_hash ON sessions(token_hash);
CREATE INDEX idx_sessions_expires_at ON sessions(expires_at);

-- Analytics ingest tokens (hashed, product-scoped)
CREATE TABLE IF NOT EXISTS analytics_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  token_hash VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT NOW(),
  revoked_at TIMESTAMP,
  last_used_at TIMESTAMP
);

CREATE INDEX idx_analytics_tokens_product_id ON analytics_tokens(product_id);
CREATE INDEX idx_analytics_tokens_token_hash ON analytics_tokens(token_hash);

-- Briefs (existing table, referenced in requirements)
CREATE TABLE IF NOT EXISTS briefs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  enriched BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Content items
CREATE TABLE IF NOT EXISTS content_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  brief_id UUID REFERENCES briefs(id) ON DELETE SET NULL,
  calendar_date DATE,
  status VARCHAR(50) DEFAULT 'draft', -- draft, approved, published, rejected
  variants JSONB DEFAULT '[]'::jsonb, -- array of {id, content, platform, warnings}
  published_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_content_items_product_id ON content_items(product_id);
CREATE INDEX idx_content_items_status ON content_items(status);
CREATE INDEX idx_content_items_calendar_date ON content_items(calendar_date);

-- Audit log for content edits
CREATE TABLE IF NOT EXISTS content_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content_item_id UUID NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  action VARCHAR(50) NOT NULL, -- edit_variant, approve, reject, schedule
  variant_id UUID,
  old_value JSONB,
  new_value JSONB,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_content_audit_log_content_item_id ON content_audit_log(content_item_id);

