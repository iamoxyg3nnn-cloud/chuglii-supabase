-- 017: recently scraped videos first + real recommendation ranking
--
-- Two user-visible bugs:
--   1. "Newest First" was sorting on source publish date, so freshly ingested
--      clips with older source dates stayed buried on every feed page.
--   2. Watch pages called "related" RPCs that matched ANY shared tag/category
--      and ordered by all-time views, returning the same handful of clips on
--      every page (plus mirrored duplicates of the video being watched).
--
-- This migration keeps all filters/permissions unchanged; it only changes the
-- ORDER BY of the list RPCs and replaces the three related-video RPCs.

-- Newest = most recently ingested (scraped_at), not source publish date.
CREATE OR REPLACE FUNCTION public.scraper_get_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    SELECT * FROM scraper.videos
    WHERE (p_source_site IS NULL OR source_site = p_source_site)
      -- Category Filter
      AND (
          p_category IS NULL 
          OR lower(trim(p_category)) IN ('all', 'viral-mms')
          OR lower(trim(p_category)) = ANY(categories)
          OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
      )
      -- Tag / Section Filter
      AND (
          p_tag IS NULL 
          OR lower(trim(p_tag)) = 'all'
          OR lower(trim(p_tag)) = ANY(tags)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
          OR lower(trim(p_tag)) = ANY(categories)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(categories)
          OR (lower(trim(p_tag)) IN ('bangladeshi', 'bangladesi') AND ('bangladesi' = ANY(categories) OR 'bangladeshi' = ANY(tags)))
          OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || lower(replace(trim(p_tag), '-', ' ')) || '%'
      )
      -- Multi-Word Search
      AND (
          p_search IS NULL 
          OR trim(p_search) = ''
          OR NOT EXISTS (
              SELECT 1
              FROM unnest(string_to_array(trim(regexp_replace(lower(p_search), '\s+', ' ', 'g')), ' ')) AS word
              WHERE word <> ''
                AND NOT (
                  lower(title) LIKE '%' || word || '%'
                  OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || word || '%'
                  OR lower(array_to_string(tags, ' ')) LIKE '%' || word || '%'
                  OR lower(array_to_string(categories, ' ')) LIKE '%' || word || '%'
                  OR lower(coalesce(array_to_string(actors, ' '), '')) LIKE '%' || word || '%'
                )
          )
      )
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

GRANT EXECUTE ON FUNCTION public.scraper_get_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- Newest = most recently ingested (scraped_at), not source publish date.
CREATE OR REPLACE FUNCTION public.scraper_get_japanese_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.japanese_videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    SELECT * FROM scraper.japanese_videos
    WHERE (p_source_site IS NULL OR source_site = p_source_site)
      -- Category Filter
      AND (
          p_category IS NULL 
          OR lower(trim(p_category)) IN ('all', 'japanese')
          OR lower(trim(p_category)) = ANY(categories)
          OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
      )
      -- Tag Filter
      AND (
          p_tag IS NULL 
          OR lower(trim(p_tag)) = 'all'
          OR lower(trim(p_tag)) = ANY(tags)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
          OR lower(trim(p_tag)) = ANY(categories)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(categories)
          OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || lower(replace(trim(p_tag), '-', ' ')) || '%'
      )
      -- Multi-Word Search (maker codes like FC2, SNOS, titles, tags, actors)
      AND (
          p_search IS NULL 
          OR trim(p_search) = ''
          OR NOT EXISTS (
              SELECT 1
              FROM unnest(string_to_array(trim(regexp_replace(lower(p_search), '\s+', ' ', 'g')), ' ')) AS word
              WHERE word <> ''
                AND NOT (
                  lower(title) LIKE '%' || word || '%'
                  OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || word || '%'
                  OR lower(array_to_string(tags, ' ')) LIKE '%' || word || '%'
                  OR lower(array_to_string(categories, ' ')) LIKE '%' || word || '%'
                  OR lower(coalesce(array_to_string(actors, ' '), '')) LIKE '%' || word || '%'
                )
          )
      )
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

GRANT EXECUTE ON FUNCTION public.scraper_get_japanese_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- Newest = most recently ingested (scraped_at), not source publish date.
CREATE OR REPLACE FUNCTION public.scraper_get_myanmar_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.myanmar_videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    SELECT * FROM scraper.myanmar_videos
    WHERE (p_source_site IS NULL OR source_site = p_source_site)
      -- Category Filter
      AND (
          p_category IS NULL 
          OR lower(trim(p_category)) IN ('all', 'myanmar')
          OR lower(trim(p_category)) = ANY(categories)
          OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
      )
      -- Tag Filter
      AND (
          p_tag IS NULL 
          OR lower(trim(p_tag)) = 'all'
          OR lower(trim(p_tag)) = ANY(tags)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
          OR lower(trim(p_tag)) = ANY(categories)
      )
      -- Search Filter
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

GRANT EXECUTE ON FUNCTION public.scraper_get_myanmar_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- Newest = most recently ingested for scraper_get_onlyfans_videos.
CREATE OR REPLACE FUNCTION public.scraper_get_onlyfans_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.onlyfans_videos
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
BEGIN
    RETURN QUERY
    SELECT ov.*
    FROM scraper.onlyfans_videos ov
    WHERE (p_source_site IS NULL OR ov.source_site = p_source_site)
      AND (p_tag IS NULL OR lower(trim(p_tag)) = 'all' OR ov.tags @> ARRAY[lower(trim(p_tag))] OR ov.actors @> ARRAY[trim(p_tag)])
      AND (p_category IS NULL OR lower(trim(p_category)) = 'all' OR ov.categories @> ARRAY[lower(trim(p_category))])
      AND (p_search IS NULL OR ov.title ILIKE '%' || trim(p_search) || '%')
      AND ov.status = 'active'
      AND (ov.full_video_url IS NOT NULL AND ov.full_video_url <> '')
    ORDER BY
        CASE WHEN p_sort = 'newest' THEN ov.scraped_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'views' THEN ov.views_count END DESC NULLS LAST,
        CASE WHEN p_sort = 'rating' THEN ov.rating_score END DESC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN ov.published_at END ASC NULLS LAST,
        CASE WHEN p_sort = 'quality' THEN ov.quality_score END DESC NULLS LAST,
        ov.published_at DESC NULLS LAST,
        ov.scraped_at DESC,
        ov.id DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.scraper_get_onlyfans_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- Newest = most recently ingested for scraper_get_voyeurhouse_videos.
CREATE OR REPLACE FUNCTION public.scraper_get_voyeurhouse_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.voyeurhouse_videos
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
BEGIN
    RETURN QUERY
    SELECT vv.*
    FROM scraper.voyeurhouse_videos vv
    WHERE (p_source_site IS NULL OR lower(trim(p_source_site)) = 'all' OR vv.source_site = p_source_site)
      AND (p_tag IS NULL OR lower(trim(p_tag)) = 'all' OR vv.tags @> ARRAY[lower(trim(p_tag))] OR vv.actors @> ARRAY[trim(p_tag)])
      AND (p_category IS NULL OR lower(trim(p_category)) = 'all' OR vv.categories @> ARRAY[lower(trim(p_category))])
      AND (p_search IS NULL OR vv.title ILIKE '%' || trim(p_search) || '%')
      AND vv.status = 'active'
      AND (vv.full_video_url IS NOT NULL AND vv.full_video_url <> '')
    ORDER BY
        CASE WHEN p_sort = 'newest' THEN vv.scraped_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'views' THEN vv.views_count END DESC NULLS LAST,
        CASE WHEN p_sort = 'rating' THEN vv.rating_score END DESC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN vv.published_at END ASC NULLS LAST,
        CASE WHEN p_sort = 'quality' THEN vv.quality_score END DESC NULLS LAST,
        vv.published_at DESC NULLS LAST,
        vv.scraped_at DESC,
        vv.id DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.scraper_get_voyeurhouse_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- Newest = most recently ingested for scraper_get_hotscopesvoyeurhouse_videos.
CREATE OR REPLACE FUNCTION public.scraper_get_hotscopesvoyeurhouse_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.hotscopesvoyeurhouse_videos
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $fn$
BEGIN
    RETURN QUERY
    SELECT vv.*
    FROM scraper.hotscopesvoyeurhouse_videos vv
    WHERE (p_source_site IS NULL OR lower(trim(p_source_site)) = 'all' OR vv.source_site = p_source_site)
      AND (p_tag IS NULL OR lower(trim(p_tag)) = 'all' OR vv.tags @> ARRAY[lower(trim(p_tag))] OR vv.actors @> ARRAY[trim(p_tag)])
      AND (p_category IS NULL OR lower(trim(p_category)) = 'all' OR vv.categories @> ARRAY[lower(trim(p_category))])
      AND (p_search IS NULL OR vv.title ILIKE '%' || trim(p_search) || '%')
      AND vv.status = 'active'
      AND (vv.full_video_url IS NOT NULL AND vv.full_video_url <> '')
    ORDER BY
        CASE WHEN p_sort = 'newest' THEN vv.scraped_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'views' THEN vv.views_count END DESC NULLS LAST,
        CASE WHEN p_sort = 'rating' THEN vv.rating_score END DESC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN vv.published_at END ASC NULLS LAST,
        CASE WHEN p_sort = 'quality' THEN vv.quality_score END DESC NULLS LAST,
        vv.published_at DESC NULLS LAST,
        vv.scraped_at DESC,
        vv.id DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.scraper_get_hotscopesvoyeurhouse_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- Newest = most recently ingested for scraper_get_reallifecamto_videos.
CREATE OR REPLACE FUNCTION public.scraper_get_reallifecamto_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.reallifecamto_videos
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $fn$
BEGIN
    RETURN QUERY
    SELECT vv.*
    FROM scraper.reallifecamto_videos vv
    WHERE (p_source_site IS NULL OR lower(trim(p_source_site)) = 'all' OR vv.source_site = p_source_site)
      AND (p_tag IS NULL OR lower(trim(p_tag)) = 'all' OR vv.tags @> ARRAY[lower(trim(p_tag))] OR vv.actors @> ARRAY[trim(p_tag)])
      AND (p_category IS NULL OR lower(trim(p_category)) = 'all' OR vv.categories @> ARRAY[lower(trim(p_category))])
      AND (p_search IS NULL OR vv.title ILIKE '%' || trim(p_search) || '%')
      AND vv.status = 'active'
      AND (vv.full_video_url IS NOT NULL AND vv.full_video_url <> '')
    ORDER BY
        CASE WHEN p_sort = 'newest' THEN vv.scraped_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'views' THEN vv.views_count END DESC NULLS LAST,
        CASE WHEN p_sort = 'rating' THEN vv.rating_score END DESC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN vv.published_at END ASC NULLS LAST,
        CASE WHEN p_sort = 'quality' THEN vv.quality_score END DESC NULLS LAST,
        vv.published_at DESC NULLS LAST,
        vv.scraped_at DESC,
        vv.id DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.scraper_get_reallifecamto_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- Newest = most recently ingested for scraper_get_hotscopesspygasm_videos.
CREATE OR REPLACE FUNCTION public.scraper_get_hotscopesspygasm_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.hotscopesspygasm_videos
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $fn$
BEGIN
    RETURN QUERY
    SELECT vv.*
    FROM scraper.hotscopesspygasm_videos vv
    WHERE (p_source_site IS NULL OR lower(trim(p_source_site)) = 'all' OR vv.source_site = p_source_site)
      AND (p_tag IS NULL OR lower(trim(p_tag)) = 'all' OR vv.tags @> ARRAY[lower(trim(p_tag))] OR vv.actors @> ARRAY[trim(p_tag)])
      AND (p_category IS NULL OR lower(trim(p_category)) = 'all' OR vv.categories @> ARRAY[lower(trim(p_category))])
      AND (p_search IS NULL OR vv.title ILIKE '%' || trim(p_search) || '%')
      AND vv.status = 'active'
      AND (vv.full_video_url IS NOT NULL AND vv.full_video_url <> '')
    ORDER BY
        CASE WHEN p_sort = 'newest' THEN vv.scraped_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'views' THEN vv.views_count END DESC NULLS LAST,
        CASE WHEN p_sort = 'rating' THEN vv.rating_score END DESC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN vv.published_at END ASC NULLS LAST,
        CASE WHEN p_sort = 'quality' THEN vv.quality_score END DESC NULLS LAST,
        vv.published_at DESC NULLS LAST,
        vv.scraped_at DESC,
        vv.id DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.scraper_get_hotscopesspygasm_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- Newest = most recently ingested for scraper_get_hotscopesreallifecam_videos.
CREATE OR REPLACE FUNCTION public.scraper_get_hotscopesreallifecam_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.hotscopesreallifecam_videos
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $fn$
BEGIN
    RETURN QUERY
    SELECT vv.*
    FROM scraper.hotscopesreallifecam_videos vv
    WHERE (p_source_site IS NULL OR lower(trim(p_source_site)) = 'all' OR vv.source_site = p_source_site)
      AND (p_tag IS NULL OR lower(trim(p_tag)) = 'all' OR vv.tags @> ARRAY[lower(trim(p_tag))] OR vv.actors @> ARRAY[trim(p_tag)])
      AND (p_category IS NULL OR lower(trim(p_category)) = 'all' OR vv.categories @> ARRAY[lower(trim(p_category))])
      AND (p_search IS NULL OR vv.title ILIKE '%' || trim(p_search) || '%')
      AND vv.status = 'active'
      AND (vv.full_video_url IS NOT NULL AND vv.full_video_url <> '')
    ORDER BY
        CASE WHEN p_sort = 'newest' THEN vv.scraped_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'views' THEN vv.views_count END DESC NULLS LAST,
        CASE WHEN p_sort = 'rating' THEN vv.rating_score END DESC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN vv.published_at END ASC NULLS LAST,
        CASE WHEN p_sort = 'quality' THEN vv.quality_score END DESC NULLS LAST,
        vv.published_at DESC NULLS LAST,
        vv.scraped_at DESC,
        vv.id DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.scraper_get_hotscopesreallifecam_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- ============================================================================
-- RECOMMENDATIONS: relevance-ranked, de-duplicated, freshness-aware
-- ============================================================================
-- Replaces the old "any shared tag + ORDER BY views" query, which always
-- returned the same globally popular clips for every watch page. New rules:
--   * Rare tags/actors count more than generic ones (frequency-derived weight)
--   * Near-duplicate titles (same clip mirrored on several sites) collapse
--   * The current video and its mirrors are never suggested
--   * Freshly scraped items win ties; zero-overlap items act as a fallback
-- ============================================================================

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
            lower(regexp_replace(coalesce(title, ''), '[^a-z0-9]+', ' ', 'g')) AS title_key
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
            lower(regexp_replace(coalesce(v.title, ''), '[^a-z0-9]+', ' ', 'g')) AS title_key
        FROM scraper.videos v, target t
        WHERE v.id <> p_video_id
          AND lower(regexp_replace(coalesce(v.title, ''), '[^a-z0-9]+', ' ', 'g')) <> t.title_key
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
            lower(regexp_replace(coalesce(title, ''), '[^a-z0-9]+', ' ', 'g')) AS title_key
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
            lower(regexp_replace(coalesce(v.title, ''), '[^a-z0-9]+', ' ', 'g')) AS title_key
        FROM scraper.japanese_videos v, target t
        WHERE v.id <> p_video_id
          AND lower(regexp_replace(coalesce(v.title, ''), '[^a-z0-9]+', ' ', 'g')) <> t.title_key
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
            lower(regexp_replace(coalesce(title, ''), '[^a-z0-9]+', ' ', 'g')) AS title_key
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
            lower(regexp_replace(coalesce(v.title, ''), '[^a-z0-9]+', ' ', 'g')) AS title_key
        FROM scraper.myanmar_videos v, target t
        WHERE v.id <> p_video_id
          AND lower(regexp_replace(coalesce(v.title, ''), '[^a-z0-9]+', ' ', 'g')) <> t.title_key
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
