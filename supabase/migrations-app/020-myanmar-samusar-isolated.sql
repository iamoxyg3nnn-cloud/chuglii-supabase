-- ============================================================================
-- MIGRATION: Isolated Samusar table and RPCs (Myanmar Category)
-- Table: scraper.samusar_videos (completely isolated from scraper.myanmar_videos)
-- ============================================================================

CREATE TABLE IF NOT EXISTS scraper.samusar_videos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_site TEXT NOT NULL DEFAULT 'samusar' CHECK (source_site = 'samusar'),
    source_post_id TEXT NOT NULL,
    title TEXT NOT NULL,
    slug TEXT,
    detail_url TEXT NOT NULL,
    full_video_url TEXT,
    video_mime_type TEXT DEFAULT 'video/mp4',
    trailer_preview_url TEXT,
    thumbnail_url TEXT,
    clean_thumbnail_url TEXT,
    duration_seconds INTEGER,
    duration_formatted VARCHAR(32),
    views_count BIGINT DEFAULT 0,
    views_raw VARCHAR(64) DEFAULT '0',
    rating_score NUMERIC(5,2) DEFAULT 0.0,
    rating_raw VARCHAR(32) DEFAULT '0%',
    categories TEXT[] DEFAULT '{myanmar}',
    tags TEXT[] DEFAULT '{}',
    actors TEXT[] DEFAULT '{}',
    status TEXT DEFAULT 'active',
    published_at TIMESTAMPTZ,
    scraped_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    raw_payload JSONB DEFAULT '{}'::jsonb,
    CONSTRAINT uq_samusar_videos UNIQUE (source_site, source_post_id)
);

ALTER TABLE scraper.samusar_videos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_all_samusar_videos ON scraper.samusar_videos;
CREATE POLICY service_role_all_samusar_videos
    ON scraper.samusar_videos FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS anon_select_samusar_videos ON scraper.samusar_videos;
CREATE POLICY anon_select_samusar_videos
    ON scraper.samusar_videos FOR SELECT TO anon, authenticated USING (status = 'active');

CREATE INDEX IF NOT EXISTS idx_samusar_videos_source ON scraper.samusar_videos (source_site, source_post_id);
CREATE INDEX IF NOT EXISTS idx_samusar_videos_scraped ON scraper.samusar_videos (scraped_at DESC);
CREATE INDEX IF NOT EXISTS idx_samusar_videos_published ON scraper.samusar_videos (published_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_samusar_videos_views ON scraper.samusar_videos (views_count DESC);
CREATE INDEX IF NOT EXISTS idx_samusar_videos_duration ON scraper.samusar_videos (duration_seconds DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_samusar_videos_tags ON scraper.samusar_videos USING gin(tags);
CREATE INDEX IF NOT EXISTS idx_samusar_videos_categories ON scraper.samusar_videos USING gin(categories);
CREATE INDEX IF NOT EXISTS idx_samusar_videos_actors ON scraper.samusar_videos USING gin(actors);

CREATE OR REPLACE FUNCTION public.scraper_upsert_samusar_videos(items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = scraper, public
AS $$
DECLARE
    affected_count integer;
BEGIN
    WITH raw_items AS (
        SELECT DISTINCT ON (NULLIF(btrim(x->>'source_post_id'), ''))
            'samusar'::text AS source_site,
            NULLIF(btrim(x->>'source_post_id'), '') AS source_post_id,
            COALESCE(NULLIF(btrim(x->>'title'), ''), 'Myanmar Video') AS title,
            NULLIF(btrim(x->>'slug'), '') AS slug,
            COALESCE(NULLIF(btrim(x->>'detail_url'), ''), '') AS detail_url,
            NULLIF(btrim(x->>'full_video_url'), '') AS full_video_url,
            COALESCE(NULLIF(btrim(x->>'video_mime_type'), ''), 'video/mp4') AS video_mime_type,
            NULLIF(btrim(x->>'trailer_preview_url'), '') AS trailer_preview_url,
            NULLIF(btrim(x->>'thumbnail_url'), '') AS thumbnail_url,
            NULLIF(btrim(x->>'clean_thumbnail_url'), '') AS clean_thumbnail_url,
            (x->>'duration_seconds')::integer AS duration_seconds,
            NULLIF(btrim(x->>'duration_formatted'), '')::varchar AS duration_formatted,
            COALESCE((x->>'views_count')::bigint, 0) AS views_count,
            COALESCE(NULLIF(btrim(x->>'views_raw'), ''), '0')::varchar AS views_raw,
            COALESCE((x->>'rating_score')::numeric(5,2), 0.0) AS rating_score,
            COALESCE(NULLIF(btrim(x->>'rating_raw'), ''), '0%')::varchar AS rating_raw,
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(x->'categories', '["myanmar"]'::jsonb))), ARRAY['myanmar']::text[]) AS categories,
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(x->'tags', '[]'::jsonb))), ARRAY[]::text[]) AS tags,
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(x->'actors', '[]'::jsonb))), ARRAY[]::text[]) AS actors,
            COALESCE(NULLIF(btrim(x->>'status'), ''), 'active') AS status,
            CASE WHEN NULLIF(btrim(x->>'published_at'), '') IS NOT NULL
                 THEN (x->>'published_at')::timestamptz ELSE NULL END AS published_at,
            COALESCE(x->'raw_payload', '{}'::jsonb) AS raw_payload
        FROM jsonb_array_elements(items) AS x
        WHERE NULLIF(btrim(x->>'source_post_id'), '') IS NOT NULL
          AND NULLIF(btrim(x->>'full_video_url'), '') IS NOT NULL
    )
    INSERT INTO scraper.samusar_videos (
        source_site, source_post_id, title, slug, detail_url,
        full_video_url, video_mime_type, trailer_preview_url,
        thumbnail_url, clean_thumbnail_url, duration_seconds, duration_formatted,
        views_count, views_raw, rating_score, rating_raw,
        categories, tags, actors, status, published_at, raw_payload, updated_at
    )
    SELECT
        source_site, source_post_id, title, slug, detail_url,
        full_video_url, video_mime_type, trailer_preview_url,
        thumbnail_url, clean_thumbnail_url, duration_seconds, duration_formatted,
        views_count, views_raw, rating_score, rating_raw,
        categories, tags, actors, status, published_at, raw_payload, now()
    FROM raw_items
    ON CONFLICT (source_site, source_post_id) DO UPDATE SET
        title = EXCLUDED.title,
        slug = COALESCE(EXCLUDED.slug, scraper.samusar_videos.slug),
        detail_url = EXCLUDED.detail_url,
        full_video_url = EXCLUDED.full_video_url,
        video_mime_type = EXCLUDED.video_mime_type,
        trailer_preview_url = COALESCE(EXCLUDED.trailer_preview_url, scraper.samusar_videos.trailer_preview_url),
        thumbnail_url = COALESCE(EXCLUDED.thumbnail_url, scraper.samusar_videos.thumbnail_url),
        clean_thumbnail_url = COALESCE(EXCLUDED.clean_thumbnail_url, scraper.samusar_videos.clean_thumbnail_url),
        duration_seconds = COALESCE(EXCLUDED.duration_seconds, scraper.samusar_videos.duration_seconds),
        duration_formatted = COALESCE(EXCLUDED.duration_formatted, scraper.samusar_videos.duration_formatted),
        views_count = GREATEST(EXCLUDED.views_count, scraper.samusar_videos.views_count),
        views_raw = COALESCE(EXCLUDED.views_raw, scraper.samusar_videos.views_raw),
        rating_score = COALESCE(EXCLUDED.rating_score, scraper.samusar_videos.rating_score),
        rating_raw = COALESCE(EXCLUDED.rating_raw, scraper.samusar_videos.rating_raw),
        categories = EXCLUDED.categories,
        tags = EXCLUDED.tags,
        actors = EXCLUDED.actors,
        status = EXCLUDED.status,
        published_at = COALESCE(EXCLUDED.published_at, scraper.samusar_videos.published_at),
        raw_payload = EXCLUDED.raw_payload,
        updated_at = now();

    GET DIAGNOSTICS affected_count = ROW_COUNT;
    RETURN jsonb_build_object('success', true, 'count', affected_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.scraper_get_samusar_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.samusar_videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    SELECT * FROM scraper.samusar_videos
    WHERE (p_source_site IS NULL OR source_site = p_source_site)
      AND (
          p_category IS NULL
          OR lower(trim(p_category)) IN ('all', 'myanmar')
          OR lower(trim(p_category)) = ANY(categories)
          OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
      )
      AND (
          p_tag IS NULL
          OR lower(trim(p_tag)) = 'all'
          OR lower(trim(p_tag)) = ANY(tags)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
          OR lower(trim(p_tag)) = ANY(categories)
      )
      AND (
          p_search IS NULL
          OR trim(p_search) = ''
          OR (
              SELECT bool_and(
                lower(title) LIKE '%' || word || '%'
                OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || word || '%'
                OR lower(array_to_string(tags, ' ')) LIKE '%' || word || '%'
                OR lower(array_to_string(categories, ' ')) LIKE '%' || word || '%'
              )
              FROM unnest(string_to_array(lower(trim(p_search)), ' ')) AS word
              WHERE length(word) > 0
          )
      )
      AND status = 'active'
      AND full_video_url IS NOT NULL AND full_video_url <> ''
    ORDER BY
      CASE WHEN p_sort = 'newest' THEN scraped_at END DESC NULLS LAST,
      CASE WHEN p_sort = 'views' THEN views_count END DESC NULLS LAST,
      CASE WHEN p_sort = 'rating' THEN rating_score END DESC NULLS LAST,
      CASE WHEN p_sort = 'longest' THEN duration_seconds END DESC NULLS LAST,
      CASE WHEN p_sort = 'oldest' THEN published_at END ASC NULLS LAST,
      published_at DESC NULLS LAST,
      scraped_at DESC,
      id DESC
    LIMIT p_limit OFFSET p_offset;
$$;

CREATE OR REPLACE FUNCTION public.scraper_count_samusar_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL
)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    SELECT count(*) FROM scraper.samusar_videos
    WHERE (p_source_site IS NULL OR source_site = p_source_site)
      AND (
          p_category IS NULL
          OR lower(trim(p_category)) IN ('all', 'myanmar')
          OR lower(trim(p_category)) = ANY(categories)
          OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
      )
      AND (
          p_tag IS NULL
          OR lower(trim(p_tag)) = 'all'
          OR lower(trim(p_tag)) = ANY(tags)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
          OR lower(trim(p_tag)) = ANY(categories)
      )
      AND (
          p_search IS NULL
          OR trim(p_search) = ''
          OR (
              SELECT bool_and(
                lower(title) LIKE '%' || word || '%'
                OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || word || '%'
                OR lower(array_to_string(tags, ' ')) LIKE '%' || word || '%'
                OR lower(array_to_string(categories, ' ')) LIKE '%' || word || '%'
              )
              FROM unnest(string_to_array(lower(trim(p_search)), ' ')) AS word
              WHERE length(word) > 0
          )
      )
      AND status = 'active'
      AND full_video_url IS NOT NULL AND full_video_url <> '';
$$;

CREATE OR REPLACE FUNCTION public.scraper_get_samusar_video_by_id(p_id text)
RETURNS SETOF scraper.samusar_videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    SELECT * FROM scraper.samusar_videos
    WHERE id::text = p_id
      AND status = 'active'
      AND full_video_url IS NOT NULL AND full_video_url <> ''
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.scraper_upsert_samusar_videos(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scraper_upsert_samusar_videos(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.scraper_get_samusar_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scraper_count_samusar_videos(text, text, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scraper_get_samusar_video_by_id(text) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
