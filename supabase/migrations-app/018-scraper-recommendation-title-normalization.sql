-- 018: Unicode-aware recommendation de-duplication
--
-- The 017 title key stripped every non-ASCII character. Burmese (and some
-- Japanese) titles therefore collapsed to spaces, which made unrelated clips
-- look like duplicates and could suppress valid recommendations. Use the
-- locale-aware [[:alnum:]] class instead, trim the result, and never exclude
-- candidates when the current title normalizes to an empty key.

CREATE OR REPLACE FUNCTION public.scraper_get_related_videos(
    p_video_id uuid,
    p_limit int DEFAULT 8
)
RETURNS SETOF scraper.videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    WITH target AS (
        SELECT
            tags, categories, actors, source_site,
            lower(btrim(regexp_replace(coalesce(title, ''), '[^[:alnum:]]+', ' ', 'g'))) AS title_key
        FROM scraper.videos
        WHERE id = p_video_id
        LIMIT 1
    ),
    tag_freq AS (
        SELECT t_tag AS tag, count(*)::numeric AS n
        FROM scraper.videos v, target t, unnest(t.tags) t_tag
        WHERE t_tag = ANY (v.tags)
        GROUP BY t_tag
    ),
    category_freq AS (
        SELECT t_category AS category, count(*)::numeric AS n
        FROM scraper.videos v, target t, unnest(t.categories) t_category
        WHERE t_category = ANY (v.categories)
        GROUP BY t_category
    ),
    scored AS (
        SELECT
            v AS video,
            LEAST(12.0,
                (SELECT coalesce(sum(LEAST(4.0, GREATEST(1.0, 300.0 / f.n))), 0)
                 FROM unnest(v.tags) x JOIN tag_freq f ON f.tag = x)
              + (SELECT coalesce(sum(LEAST(3.0, GREATEST(1.0, 150.0 / f.n))), 0)
                 FROM unnest(v.categories) x JOIN category_freq f ON f.category = x)
              + (CASE WHEN v.actors && (SELECT actors FROM target) THEN 3.0 ELSE 0 END)
              + (CASE WHEN v.source_site = (SELECT source_site FROM target) THEN 1.0 ELSE 0 END)
            ) AS relevance,
            lower(btrim(regexp_replace(coalesce(v.title, ''), '[^[:alnum:]]+', ' ', 'g'))) AS title_key
        FROM scraper.videos v, target t
        WHERE v.id <> p_video_id
          AND (t.title_key = '' OR lower(btrim(regexp_replace(coalesce(v.title, ''), '[^[:alnum:]]+', ' ', 'g'))) <> t.title_key)
    ),
    ranked AS (
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY coalesce(nullif(s.title_key, ''), (s.video).id::text)
                   ORDER BY s.relevance DESC, (s.video).scraped_at DESC,
                            (s.video).views_count DESC, (s.video).id DESC
               ) AS dedupe_rank
        FROM scored s
    )
    SELECT (r.video).*
    FROM ranked r
    WHERE r.dedupe_rank = 1
    ORDER BY r.relevance DESC, (r.video).scraped_at DESC,
             (r.video).views_count DESC, (r.video).id DESC
    LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.scraper_get_related_videos(uuid, int) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.scraper_get_japanese_related_videos(
    p_video_id uuid,
    p_limit int DEFAULT 8
)
RETURNS SETOF scraper.japanese_videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    WITH target AS (
        SELECT
            tags, categories, actors, source_site,
            lower(btrim(regexp_replace(coalesce(title, ''), '[^[:alnum:]]+', ' ', 'g'))) AS title_key
        FROM scraper.japanese_videos
        WHERE id = p_video_id
        LIMIT 1
    ),
    tag_freq AS (
        SELECT t_tag AS tag, count(*)::numeric AS n
        FROM scraper.japanese_videos v, target t, unnest(t.tags) t_tag
        WHERE t_tag = ANY (v.tags)
        GROUP BY t_tag
    ),
    category_freq AS (
        SELECT t_category AS category, count(*)::numeric AS n
        FROM scraper.japanese_videos v, target t, unnest(t.categories) t_category
        WHERE t_category = ANY (v.categories)
        GROUP BY t_category
    ),
    scored AS (
        SELECT
            v AS video,
            LEAST(12.0,
                (SELECT coalesce(sum(LEAST(4.0, GREATEST(1.0, 300.0 / f.n))), 0)
                 FROM unnest(v.tags) x JOIN tag_freq f ON f.tag = x)
              + (SELECT coalesce(sum(LEAST(3.0, GREATEST(1.0, 150.0 / f.n))), 0)
                 FROM unnest(v.categories) x JOIN category_freq f ON f.category = x)
              + (CASE WHEN v.actors && (SELECT actors FROM target) THEN 3.0 ELSE 0 END)
              + (CASE WHEN v.source_site = (SELECT source_site FROM target) THEN 1.0 ELSE 0 END)
            ) AS relevance,
            lower(btrim(regexp_replace(coalesce(v.title, ''), '[^[:alnum:]]+', ' ', 'g'))) AS title_key
        FROM scraper.japanese_videos v, target t
        WHERE v.id <> p_video_id
          AND (t.title_key = '' OR lower(btrim(regexp_replace(coalesce(v.title, ''), '[^[:alnum:]]+', ' ', 'g'))) <> t.title_key)
    ),
    ranked AS (
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY coalesce(nullif(s.title_key, ''), (s.video).id::text)
                   ORDER BY s.relevance DESC, (s.video).scraped_at DESC,
                            (s.video).views_count DESC, (s.video).id DESC
               ) AS dedupe_rank
        FROM scored s
    )
    SELECT (r.video).*
    FROM ranked r
    WHERE r.dedupe_rank = 1
    ORDER BY r.relevance DESC, (r.video).scraped_at DESC,
             (r.video).views_count DESC, (r.video).id DESC
    LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.scraper_get_japanese_related_videos(uuid, int) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.scraper_get_myanmar_related_videos(
    p_video_id uuid,
    p_limit int DEFAULT 8
)
RETURNS SETOF scraper.myanmar_videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    WITH target AS (
        SELECT
            tags, categories, actors, source_site,
            lower(btrim(regexp_replace(coalesce(title, ''), '[^[:alnum:]]+', ' ', 'g'))) AS title_key
        FROM scraper.myanmar_videos
        WHERE id = p_video_id
        LIMIT 1
    ),
    tag_freq AS (
        SELECT t_tag AS tag, count(*)::numeric AS n
        FROM scraper.myanmar_videos v, target t, unnest(t.tags) t_tag
        WHERE t_tag = ANY (v.tags)
        GROUP BY t_tag
    ),
    category_freq AS (
        SELECT t_category AS category, count(*)::numeric AS n
        FROM scraper.myanmar_videos v, target t, unnest(t.categories) t_category
        WHERE t_category = ANY (v.categories)
        GROUP BY t_category
    ),
    scored AS (
        SELECT
            v AS video,
            LEAST(12.0,
                (SELECT coalesce(sum(LEAST(4.0, GREATEST(1.0, 300.0 / f.n))), 0)
                 FROM unnest(v.tags) x JOIN tag_freq f ON f.tag = x)
              + (SELECT coalesce(sum(LEAST(3.0, GREATEST(1.0, 150.0 / f.n))), 0)
                 FROM unnest(v.categories) x JOIN category_freq f ON f.category = x)
              + (CASE WHEN v.actors && (SELECT actors FROM target) THEN 3.0 ELSE 0 END)
              + (CASE WHEN v.source_site = (SELECT source_site FROM target) THEN 1.0 ELSE 0 END)
            ) AS relevance,
            lower(btrim(regexp_replace(coalesce(v.title, ''), '[^[:alnum:]]+', ' ', 'g'))) AS title_key
        FROM scraper.myanmar_videos v, target t
        WHERE v.id <> p_video_id
          AND (t.title_key = '' OR lower(btrim(regexp_replace(coalesce(v.title, ''), '[^[:alnum:]]+', ' ', 'g'))) <> t.title_key)
    ),
    ranked AS (
        SELECT s.*,
               row_number() OVER (
                   PARTITION BY coalesce(nullif(s.title_key, ''), (s.video).id::text)
                   ORDER BY s.relevance DESC, (s.video).scraped_at DESC,
                            (s.video).views_count DESC, (s.video).id DESC
               ) AS dedupe_rank
        FROM scored s
    )
    SELECT (r.video).*
    FROM ranked r
    WHERE r.dedupe_rank = 1
    ORDER BY r.relevance DESC, (r.video).scraped_at DESC,
             (r.video).views_count DESC, (r.video).id DESC
    LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.scraper_get_myanmar_related_videos(uuid, int) TO anon, authenticated, service_role;

