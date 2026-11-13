// MxA X (Twitter) ingest edge function.
// Deploy with verify_jwt=false; auth via x-ingest-secret + ingest_secret_ok.
import { createClient } from "jsr:@supabase/supabase-js@2";

const USER_ID = "1477404002165866496";
const API_BASE = "https://api.x.com/2";
const TZ = "America/Chicago";

type Json = Record<string, unknown>;

function chicagoDate(d: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(d);
  const y = parts.find((p) => p.type === "year")?.value;
  const m = parts.find((p) => p.type === "month")?.value;
  const day = parts.find((p) => p.type === "day")?.value;
  return `${y}-${m}-${day}`;
}

function addDays(isoDate: string, delta: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  const utc = new Date(Date.UTC(y, m - 1, d));
  utc.setUTCDate(utc.getUTCDate() + delta);
  return utc.toISOString().slice(0, 10);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function fetchWithRetry(
  url: string,
  init: RequestInit,
  attempts = 3,
): Promise<Response> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(url, init);
      if (res.status === 429 || res.status >= 500) {
        await sleep(500 * (i + 1));
        lastErr = new Error(`HTTP ${res.status}`);
        continue;
      }
      return res;
    } catch (e) {
      lastErr = e;
      await sleep(500 * (i + 1));
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const secret = req.headers.get("x-ingest-secret") ?? "";
  const { data: ok, error: okErr } = await supabase.rpc("ingest_secret_ok", {
    p_given: secret,
  });
  if (okErr || !ok) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const logFail = async (message: string) => {
    await supabase.rpc("ingest_log", {
      p_job: "ingest-x",
      p_status: "failed",
      p_error: message,
      p_meta: {},
    });
  };

  try {
    let body: { start?: string; end?: string; trigger?: string; retry?: boolean } = {};
    if (req.method !== "GET" && req.headers.get("content-type")?.includes("application/json")) {
      try {
        body = await req.json();
      } catch {
        body = {};
      }
    }

    const { data: bearer } = await supabase.rpc("ingest_secret", {
      p_name: "X_BEARER_TOKEN",
    });
    if (!bearer) {
      await supabase.rpc("ingest_log", {
        p_job: "ingest-x",
        p_status: "failed",
        p_error: "missing_credentials: X_BEARER_TOKEN not set in Vault",
        p_meta: {},
      });
      return new Response(
        JSON.stringify({ error: "missing_credentials" }),
        { status: 503, headers: { "Content-Type": "application/json" } },
      );
    }

    const authHeaders = {
      Authorization: `Bearer ${String(bearer)}`,
      "Content-Type": "application/json",
    };

    const todayChi = chicagoDate(new Date());
    const yday = addDays(todayChi, -1);
    const windowEnd = body.end ?? yday;
    const windowStart = body.start ?? addDays(yday, -29);
    const startTime = new Date(`${addDays(yday, -29)}T00:00:00-06:00`).toISOString();

    // Followers EOD for yesterday
    const userRes = await fetchWithRetry(
      `${API_BASE}/users/${USER_ID}?user.fields=public_metrics`,
      { headers: authHeaders },
    );
    if (!userRes.ok) {
      throw new Error(`X user lookup failed: ${userRes.status}`);
    }
    const userJson = await userRes.json() as Json;
    const userData = (userJson.data ?? {}) as Json;
    const publicMetrics = (userData.public_metrics ?? {}) as Json;
    const followers = Number(publicMetrics.followers_count ?? 0);

    type DayAgg = {
      impressions: number;
      video_views: number;
      posts: Array<{ id: string; impressions: number; video_views: number }>;
    };
    const byDate = new Map<string, DayAgg>();
    let newestId: string | null = null;

    let nextToken: string | undefined;
    for (let page = 0; page < 20; page++) {
      const u = new URL(`${API_BASE}/users/${USER_ID}/tweets`);
      u.searchParams.set("max_results", "100");
      u.searchParams.set("exclude", "replies,retweets");
      u.searchParams.set("start_time", startTime);
      u.searchParams.set("tweet.fields", "created_at,public_metrics");
      u.searchParams.set("expansions", "attachments.media_keys");
      u.searchParams.set("media.fields", "public_metrics,type");
      if (nextToken) u.searchParams.set("pagination_token", nextToken);

      await sleep(200);
      const res = await fetchWithRetry(u.toString(), { headers: authHeaders });
      if (!res.ok) {
        const t = await res.text();
        throw new Error(`X tweets failed: ${res.status} ${t.slice(0, 200)}`);
      }
      const json = await res.json() as Json;
      const tweets = (json.data ?? []) as Json[];
      const includes = (json.includes ?? {}) as Json;
      const mediaList = (includes.media ?? []) as Json[];
      const mediaByKey = new Map<string, Json>();
      for (const m of mediaList) {
        const key = String(m.media_key ?? "");
        if (key) mediaByKey.set(key, m);
      }

      for (const tw of tweets) {
        const id = String(tw.id ?? "");
        if (!id) continue;
        if (!newestId || BigInt(id) > BigInt(newestId)) newestId = id;

        const created = String(tw.created_at ?? "");
        if (!created) continue;
        const date = chicagoDate(new Date(created));
        if (date >= todayChi) continue;
        if (date < windowStart || date > windowEnd) continue;

        const pm = (tw.public_metrics ?? {}) as Json;
        const impressions = Number(pm.impression_count ?? 0);

        let videoViews = 0;
        const attachments = (tw.attachments ?? {}) as Json;
        const keys = (attachments.media_keys ?? []) as string[];
        for (const mk of keys) {
          const media = mediaByKey.get(mk);
          if (!media) continue;
          const mpm = (media.public_metrics ?? {}) as Json;
          videoViews += Number(mpm.view_count ?? 0);
        }

        let agg = byDate.get(date);
        if (!agg) {
          agg = { impressions: 0, video_views: 0, posts: [] };
          byDate.set(date, agg);
        }
        agg.impressions += impressions;
        agg.video_views += videoViews;
        agg.posts.push({ id, impressions, video_views: videoViews });
      }

      const meta = (json.meta ?? {}) as Json;
      nextToken = typeof meta.next_token === "string" ? meta.next_token : undefined;
      if (!nextToken) break;
    }

    const metrics: Array<Record<string, unknown>> = [
      {
        metric_date: yday,
        source_id: "x",
        episode_id: null,
        metric: "followers_eod",
        value: followers,
        raw: { user_id: USER_ID, followers_count: followers },
      },
    ];

    for (const [date, agg] of byDate.entries()) {
      metrics.push({
        metric_date: date,
        source_id: "x",
        episode_id: null,
        metric: "impressions",
        value: agg.impressions,
        raw: { posts: agg.posts },
      });
      metrics.push({
        metric_date: date,
        source_id: "x",
        episode_id: null,
        metric: "video_views",
        value: agg.video_views,
        raw: { posts: agg.posts },
      });
    }

    const payload = {
      window_start: windowStart,
      window_end: windowEnd,
      meta: {
        trigger: body.trigger ?? "manual",
        newest_id: newestId,
        user_id: USER_ID,
      },
      episodes: [],
      metrics,
      dims: [],
    };

    const { data: result, error: applyErr } = await supabase.rpc("ingest_apply", {
      p_job: "ingest-x",
      p_payload: payload,
    });
    if (applyErr) throw new Error(applyErr.message);

    return new Response(JSON.stringify(result), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    const safe = message
      .replace(/Bearer\s+\S+/gi, "Bearer [redacted]")
      .replace(/AAAA[A-Za-z0-9%]*/g, "[redacted]");
    await logFail(safe);
    return new Response(JSON.stringify({ error: safe }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    });
  }
});
