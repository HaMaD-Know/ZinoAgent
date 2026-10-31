// Ordered schema migrations. Never edit a shipped migration: add a new one.
// API keys are deliberately absent from the schema: they live in the iOS Keychain.

export interface Migration { version: number; name: string; sql: string }

export const MIGRATIONS: Migration[] = [
  {
    version: 1,
    name: 'initial schema',
    sql: `
CREATE TABLE IF NOT EXISTS chat_folders (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS chats (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  title_auto INTEGER NOT NULL DEFAULT 1,
  folder_id TEXT REFERENCES chat_folders(id) ON DELETE SET NULL,
  pinned INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  model_ref TEXT,
  effort TEXT,
  settings TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_chats_updated ON chats(updated_at DESC);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  reasoning TEXT,
  created_at INTEGER NOT NULL,
  token_count INTEGER,
  token_exact INTEGER NOT NULL DEFAULT 0,
  token_model TEXT,
  batch_id TEXT,
  status TEXT NOT NULL DEFAULT 'complete',
  model_ref TEXT,
  attachments TEXT NOT NULL DEFAULT '[]',
  tool_calls TEXT NOT NULL DEFAULT '[]',
  tool_call_id TEXT,
  tool_name TEXT,
  meta TEXT NOT NULL DEFAULT '{}'
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_chat_seq ON messages(chat_id, seq);
CREATE INDEX IF NOT EXISTS idx_messages_batch ON messages(batch_id);

-- Original messages are never deleted when summarised: batches and summaries reference them.
CREATE TABLE IF NOT EXISTS batches (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  start_seq INTEGER NOT NULL,
  end_seq INTEGER NOT NULL,
  message_ids TEXT NOT NULL,
  token_count INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_batches_chat ON batches(chat_id, start_seq);

CREATE TABLE IF NOT EXISTS summaries (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  batch_id TEXT,
  level INTEGER NOT NULL DEFAULT 1,
  parent_summary_ids TEXT NOT NULL DEFAULT '[]',
  source_message_ids TEXT NOT NULL DEFAULT '[]',
  source_batch_ids TEXT NOT NULL DEFAULT '[]',
  content TEXT NOT NULL,
  token_count INTEGER NOT NULL,
  verification TEXT,
  verified INTEGER NOT NULL DEFAULT 0,
  model_ref TEXT,
  created_at INTEGER NOT NULL,
  superseded_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_summaries_chat ON summaries(chat_id, level);

CREATE TABLE IF NOT EXISTS memory_records (
  id TEXT PRIMARY KEY,
  chat_id TEXT,
  kind TEXT NOT NULL,
  content TEXT NOT NULL,
  source_message_ids TEXT NOT NULL DEFAULT '[]',
  pinned INTEGER NOT NULL DEFAULT 0,
  active INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memory_chat ON memory_records(chat_id);

CREATE TABLE IF NOT EXISTS models (
  id TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  format TEXT NOT NULL,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  sha256 TEXT,
  source_url TEXT,
  license TEXT,
  attribution TEXT,
  quantization TEXT,
  architecture TEXT,
  context_length INTEGER,
  parameters REAL,
  compatibility TEXT NOT NULL DEFAULT 'experimental',
  compatibility_notes TEXT NOT NULL DEFAULT '[]',
  metadata TEXT NOT NULL DEFAULT '{}',
  installed_at INTEGER NOT NULL,
  benchmark TEXT,
  settings TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS providers (
  id TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  base_url TEXT NOT NULL,
  key_account TEXT NOT NULL,
  key_masked TEXT,
  status TEXT NOT NULL DEFAULT 'untested',
  last_tested_at INTEGER,
  last_error TEXT,
  capabilities TEXT NOT NULL DEFAULT '[]',
  default_model TEXT,
  options TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS provider_models (
  id TEXT PRIMARY KEY,
  provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
  model_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  capabilities TEXT NOT NULL DEFAULT '[]',
  context_length INTEGER,
  output_limit INTEGER,
  metadata TEXT NOT NULL DEFAULT '{}',
  fetched_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_models ON provider_models(provider_id, model_id);

CREATE TABLE IF NOT EXISTS generation_tasks (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  model_ref TEXT NOT NULL,
  params TEXT NOT NULL DEFAULT '{}',
  progress REAL NOT NULL DEFAULT 0,
  progress_label TEXT,
  error TEXT,
  result_asset_ids TEXT NOT NULL DEFAULT '[]',
  chat_id TEXT,
  external_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_kind ON generation_tasks(kind, created_at DESC);

CREATE TABLE IF NOT EXISTS assets (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  mime TEXT NOT NULL,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  width INTEGER,
  height INTEGER,
  duration_sec REAL,
  chat_id TEXT,
  message_id TEXT,
  task_id TEXT,
  parent_asset_id TEXT,
  metadata TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_assets_kind ON assets(kind, created_at DESC);

CREATE TABLE IF NOT EXISTS file_operations (
  id TEXT PRIMARY KEY,
  root_id TEXT NOT NULL,
  op TEXT NOT NULL,
  src_path TEXT NOT NULL,
  dst_path TEXT,
  status TEXT NOT NULL,
  group_id TEXT,
  chat_id TEXT,
  metadata TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL,
  undone_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_fileops_created ON file_operations(created_at DESC);

CREATE TABLE IF NOT EXISTS downloads (
  id TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  name TEXT NOT NULL,
  url TEXT NOT NULL,
  dest_path TEXT NOT NULL,
  total_bytes INTEGER,
  received_bytes INTEGER NOT NULL DEFAULT 0,
  sha256_expected TEXT,
  status TEXT NOT NULL,
  error TEXT,
  meta TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
`,
  },
];
