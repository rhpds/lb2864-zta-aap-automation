-- Global Telemetry Platform — schema
-- Deployed by the ZTA Workshop setup automation (deploy-db-app.yml)

CREATE TABLE IF NOT EXISTS metric_categories (
    id              SERIAL PRIMARY KEY,
    slug            VARCHAR(64) UNIQUE NOT NULL,
    name            VARCHAR(128) NOT NULL,
    description     TEXT,
    icon            VARCHAR(16),
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS metrics (
    id              SERIAL PRIMARY KEY,
    category_id     INTEGER REFERENCES metric_categories(id),
    name            VARCHAR(128) NOT NULL,
    unit            VARCHAR(32) NOT NULL,
    rate_per_second NUMERIC(16, 4) NOT NULL,
    baseline_total  BIGINT DEFAULT 0,
    baseline_epoch  BIGINT DEFAULT EXTRACT(EPOCH FROM now())::BIGINT,
    confidence      NUMERIC(4, 2) DEFAULT 0.95,
    source          VARCHAR(256),
    updated_at      TIMESTAMPTZ DEFAULT now(),
    UNIQUE (category_id, name)
);

CREATE TABLE IF NOT EXISTS metric_snapshots (
    id              SERIAL PRIMARY KEY,
    metric_id       INTEGER REFERENCES metrics(id),
    value           BIGINT NOT NULL,
    recorded_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_snapshots_metric_time
    ON metric_snapshots (metric_id, recorded_at DESC);

-- Seed categories (digital first so it renders above consumption on the dashboard)
INSERT INTO metric_categories (slug, name, description, icon) VALUES
    ('digital',      'Digital Infrastructure',  'Internet and digital service metrics',      '&#x1F4BB;'),
    ('consumption',  'Global Consumption',     'Worldwide resource consumption telemetry',  '&#x1F30D;')
ON CONFLICT (slug) DO NOTHING;

-- Seed metrics (digital first to match category order)
INSERT INTO metrics (category_id, name, unit, rate_per_second, baseline_total, confidence, source) VALUES
    (
        (SELECT id FROM metric_categories WHERE slug = 'digital'),
        'Netflix "Are You Still Watching?" Prompts',
        'prompts/hr',
        13.3333,
        0,
        0.91,
        'Streaming Behavioral Analytics Institute, Q4 Engagement Study'
    ),
    (
        (SELECT id FROM metric_categories WHERE slug = 'digital'),
        'Password Reset Requests',
        'clicks/min',
        58.3333,
        0,
        0.96,
        'Federated Identity Frustration Index (FIFI), Continuous Monitoring Feed'
    ),
    (
        (SELECT id FROM metric_categories WHERE slug = 'consumption'),
        'Global Pizza Consumption',
        'slices/sec',
        350.0000,
        0,
        0.94,
        'International Pizza Telemetry Consortium (IPTC), 2025 Global Report'
    ),
    (
        (SELECT id FROM metric_categories WHERE slug = 'consumption'),
        'Toilet Paper Usage',
        'rolls/min',
        20.1667,
        0,
        0.89,
        'World Tissue & Hygiene Observatory, Annual Unraveling Index'
    ),
    (
        (SELECT id FROM metric_categories WHERE slug = 'consumption'),
        'Coffee Consumption',
        'cups/sec',
        26000.0000,
        0,
        0.97,
        'Global Caffeine Monitoring Authority (GCMA), Real-Time Brew Index'
    )
ON CONFLICT (category_id, name) DO NOTHING;
