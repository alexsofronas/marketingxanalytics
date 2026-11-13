// MxA Podbean ingest edge function.
// Deploy with verify_jwt=false; auth via x-ingest-secret + ingest_secret_ok.
import { createClient } from "jsr:@supabase/supabase-js@2";

const PODCAST_ID = "q15p9RHxwuW9";
const API_BASE = "https://api.podbean.com/v1";
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

function monthKey(isoDate: string): string {
  return isoDate.slice(0, 7).replace("-", "");
}

function firstOfMonth(yyyyMm: string): string {
  const y = yyyyMm.slice(0, 4);
  const m = yyyyMm.slice(4, 6);
  return `${y}-${m}-01`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function asNumber(v: unknown): number | null {
  if (v == null) return null;
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && !Number.isNaN(Number(v))) {
    return Number(v);
  }
  return null;
}

/** Normalize Podbean date->count maps (object or array of pairs/objects). */
function parseDateMap(raw: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (raw == null) return out;
  if (Array.isArray(raw)) {
    for (const item of raw) {
      if (Array.isArray(item) && item.length >= 2) {
        const n = asNumber(item[1]);
        if (n != null) out[String(item[0])] = n;
      } else if (item && typeof item === "object") {
        const o = item as Json;
        const date = String(o.date ?? o.day ?? o.key ?? o.name ?? "");
        const n = asNumber(o.count ?? o.value ?? o.downloads ?? o.listeners);
        if (date && n != null) out[date] = n;
      }
    }
    return out;
  }
  if (typeof raw === "object") {
    for (const [k, v] of Object.entries(raw as Json)) {
      if (v && typeof v === "object" && !Array.isArray(v)) {
        const n = asNumber(
          (v as Json).count ?? (v as Json).value ?? (v as Json).downloads,
        );
        if (n != null) out[k] = n;
      } else {
        const n = asNumber(v);
        if (n != null) out[k] = n;
      }
    }
  }
  return out;
}

function parseNameCountMap(raw: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (raw == null) return out;
  if (Array.isArray(raw)) {
    for (const item of raw) {
      if (Array.isArray(item) && item.length >= 2) {
        const n = asNumber(item[1]);
        if (n != null) out[String(item[0])] = n;
      } else if (item && typeof item === "object") {
        const o = item as Json;
        const name = String(o.name ?? o.source ?? o.country ?? o.platform ?? o.key ?? "");
        const n = asNumber(o.count ?? o.value ?? o.downloads);
        if (name && n != null) out[name] = n;
      }
    }
    return out;
  }
  if (typeof raw === "object") {
    for (const [k, v] of Object.entries(raw as Json)) {
      if (v && typeof v === "object" && !Array.isArray(v)) {
        const n = asNumber((v as Json).count ?? (v as Json).value ?? (v as Json).downloads);
        if (n != null) out[k] = n;
      } else {
        const n = asNumber(v);
        if (n != null) out[k] = n;
      }
    }
  }
  return out;
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

/** Podbean publish_time is unix seconds; normalize to ISO 8601. */
function normalizePublishAt(raw: unknown): string | null {
  if (raw == null) return null;
  if (typeof raw === "number" && Number.isFinite(raw)) {
    const ms = raw < 1e12 ? raw * 1000 : raw;
    return new Date(ms).toISOString();
  }
  if (typeof raw === "string") {
    const s = raw.trim();
    if (s === "") return null;
    if (/^\d+$/.test(s)) {
      const n = Number(s);
      const ms = n < 1e12 ? n * 1000 : n;
      return new Date(ms).toISOString();
    }
    return s;
  }
  return null;
}

async function podbeanGet(
  path: string,
  accessToken: string,
  params: Record<string, string>,
): Promise<unknown> {
  const u = new URL(`${API_BASE}${path}`);
  u.searchParams.set("access_token", accessToken);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  await sleep(200);
  const res = await fetchWithRetry(u.toString(), { method: "GET" });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Podbean GET ${path} failed: ${res.status} ${body.slice(0, 200)}`);
  }
  const json = await res.json();
  if (json && typeof json === "object" && !Array.isArray(json) && "error" in json) {
    const o = json as Json;
    const err = String(o.error ?? "");
    const desc = o.error_description != null ? String(o.error_description) : "";
    throw new Error(`Podbean GET ${path} error: ${err} ${desc}`.trimEnd());
  }
  return json;
}

async function getAccessToken(
  clientId: string,
  clientSecret: string,
  refreshToken: string | null,
): Promise<string> {
  const basic = btoa(`${clientId}:${clientSecret}`);

  const tryGrant = async (body: URLSearchParams): Promise<string | null> => {
    const res = await fetchWithRetry("https://api.podbean.com/v1/oauth/token", {
      method: "POST",
      headers: {
        Authorization: `Basic ${basic}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: body.toString(),
    });
    if (!res.ok) return null;
    const json = await res.json() as Json;
    const token = json.access_token;
    return typeof token === "string" ? token : null;
  };

  const cc = new URLSearchParams();
  cc.set("grant_type", "client_credentials");
  cc.set("podcast_id", PODCAST_ID);
  let token = await tryGrant(cc);
  if (token) return token;

  if (refreshToken) {
    const rt = new URLSearchParams();
    rt.set("grant_type", "refresh_token");
    rt.set("refresh_token", refreshToken);
    token = await tryGrant(rt);
    if (token) return token;
  }

  throw new Error("Podbean OAuth token request failed");
}

function eachDate(start: string, end: string): string[] {
  const out: string[] = [];
  let cur = start;
  while (cur <= end) {
    out.push(cur);
    cur = addDays(cur, 1);
  }
  return out;
}

function monthsTouching(start: string, end: string): string[] {
  const set = new Set<string>();
  for (const d of eachDate(start, end)) set.add(monthKey(d));
  return [...set].sort();
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
      p_job: "ingest-podbean",
      p_status: "failed",
      p_error: message,
      p_meta: {},
    });
  };

  try {
    let body: {
      start?: string;
      end?: string;
      mode?: string;
      trigger?: string;
      retry?: boolean;
    } = {};
    if (req.method !== "GET" && req.headers.get("content-type")?.includes("application/json")) {
      try {
        body = await req.json();
      } catch {
        body = {};
      }
    }

    const { data: clientId } = await supabase.rpc("ingest_secret", {
      p_name: "PODBEAN_CLIENT_ID",
    });
    const { data: clientSecret } = await supabase.rpc("ingest_secret", {
      p_name: "PODBEAN_CLIENT_SECRET",
    });

    if (!clientId || !clientSecret) {
      await supabase.rpc("ingest_log", {
        p_job: "ingest-podbean",
        p_status: "failed",
        p_error:
          "missing_credentials: PODBEAN_CLIENT_ID/PODBEAN_CLIENT_SECRET not set in Vault",
        p_meta: {},
      });
      return new Response(
        JSON.stringify({ error: "missing_credentials" }),
        { status: 503, headers: { "Content-Type": "application/json" } },
      );
    }

    const { data: refreshToken } = await supabase.rpc("ingest_secret", {
      p_name: "PODBEAN_REFRESH_TOKEN",
    });

    const accessToken = await getAccessToken(
      String(clientId),
      String(clientSecret),
      refreshToken ? String(refreshToken) : null,
    );

    // Window is complete Chicago calendar days only (yesterday and earlier).
    const todayChi = chicagoDate(new Date());
    const yday = addDays(todayChi, -1);

    let windowEnd = body.end ?? yday;
    let windowStart = body.start ?? "";

    if (!body.start) {
      const { data: prior } = await supabase
        .from("ingest_runs")
        .select("id")
        .eq("job_name", "ingest-podbean")
        .eq("status", "success")
        .limit(1);

      const hasSuccess = Array.isArray(prior) && prior.length > 0;
      if (!hasSuccess || body.mode === "catchup") {
        windowStart = addDays(yday, -89);
      } else {
        windowStart = addDays(yday, -2);
      }
    }

    // Show daily downloads
    const statsDaily = await podbeanGet("/podcastStats/stats", accessToken, {
      start: windowStart,
      end: windowEnd,
      period: "d",
    }) as Json;
    const downloadsMap = parseDateMap(
      statsDaily.stats ?? statsDaily.data ?? statsDaily,
    );

    // Unique listeners by month
    const uniquesMap: Record<string, number> = {};
    for (const ym of monthsTouching(windowStart, windowEnd)) {
      const ul = await podbeanGet(
        "/analytics/podcastDailyListener",
        accessToken,
        { month: ym },
      ) as Json;
      const parsed = parseDateMap(ul.data ?? ul.stats ?? ul.listeners ?? ul);
      for (const [d, v] of Object.entries(parsed)) {
        if (d >= windowStart && d <= windowEnd) uniquesMap[d] = v;
      }
    }

    // Monthly downloads (24 months back through current month)
    const monthEndDate = `${todayChi.slice(0, 7)}-01`;
    const [my, mm] = monthEndDate.split("-").map(Number);
    const monthStartUtc = new Date(Date.UTC(my, mm - 1 - 23, 1));
    const monthStartDate = monthStartUtc.toISOString().slice(0, 10);
    const statsMonthly = await podbeanGet("/podcastStats/stats", accessToken, {
      start: monthStartDate,
      end: monthEndDate,
      period: "m",
    }) as Json;
    const monthlyMap = parseDateMap(
      statsMonthly.stats ?? statsMonthly.data ?? statsMonthly,
    );

    // Dims: Podbean daily source/country/platform stats only allow a start
    // date within the last 30 days. Cap to the last 30 complete days.
    const dimFloor = addDays(yday, -29);
    const dimStart = windowStart > dimFloor ? windowStart : dimFloor;
    const dims: Array<Record<string, unknown>> = [];
    for (const day of eachDate(dimStart, windowEnd)) {
      for (const [path, dimType] of [
        ["/podcastStats/sources", "app"],
        ["/podcastStats/countries", "country"],
        ["/podcastStats/platforms", "platform"],
      ] as const) {
        const raw = await podbeanGet(path, accessToken, {
          start: day,
          end: day,
          period: "d",
        }) as Json;
        const map = parseNameCountMap(
          raw.stats ?? raw.data ?? raw.sources ?? raw.countries ?? raw.platforms ?? raw,
        );
        for (const [name, value] of Object.entries(map)) {
          dims.push({
            metric_date: day,
            source_id: "podbean",
            metric: "downloads",
            dim_type: dimType,
            dim_value: name,
            value,
          });
        }
      }
    }

    // Episodes (paginated)
    const episodes: Array<Record<string, unknown>> = [];
    let offset = 0;
    const limit = 100;
    for (;;) {
      const page = await podbeanGet("/episodes", accessToken, {
        offset: String(offset),
        limit: String(limit),
      }) as Json;
      const list = (page.episodes ?? page.data ?? []) as Json[];
      if (!Array.isArray(list)) break;
      for (const ep of list) {
        const id = String(ep.id ?? ep.episode_id ?? "");
        if (!id) continue;
        episodes.push({
          podbean_episode_id: id,
          title: ep.title ?? null,
          publish_at: normalizePublishAt(
            ep.pub_date ?? ep.publish_time ?? ep.published_at ?? null,
          ),
          season_number: asNumber(ep.season_number ?? ep.season),
          episode_number: asNumber(ep.episode_number ?? ep.number),
          duration_sec: asNumber(ep.duration ?? ep.duration_sec),
          permalink_url: ep.permalink_url ?? ep.url ?? null,
          raw: ep,
        });
      }
      const hasMore = Boolean(page.has_more ?? page.hasMore);
      if (!hasMore || list.length === 0) break;
      offset += limit;
    }

    // Episode-level daily stats for episodes published in last 90 days
    const cutoff = addDays(yday, -89);
    const metrics: Array<Record<string, unknown>> = [];

    for (const [d, v] of Object.entries(downloadsMap)) {
      if (d < windowStart || d > windowEnd) continue;
      metrics.push({
        metric_date: d,
        source_id: "podbean",
        episode_id: null,
        metric: "downloads",
        value: v,
        raw: { date: d, downloads: v },
      });
    }
    for (const [d, v] of Object.entries(uniquesMap)) {
      metrics.push({
        metric_date: d,
        source_id: "podbean",
        episode_id: null,
        metric: "unique_listeners_daily",
        value: v,
        raw: { date: d, unique_listeners: v },
      });
    }
    for (const [k, v] of Object.entries(monthlyMap)) {
      // Keys may be YYYY-MM, YYYY-MM-01, or YYYYMM
      let monthDate: string;
      if (/^\d{6}$/.test(k)) monthDate = firstOfMonth(k);
      else if (/^\d{4}-\d{2}$/.test(k)) monthDate = `${k}-01`;
      else if (/^\d{4}-\d{2}-\d{2}$/.test(k)) monthDate = `${k.slice(0, 7)}-01`;
      else continue;
      metrics.push({
        metric_date: monthDate,
        source_id: "podbean",
        episode_id: null,
        metric: "downloads_monthly",
        value: v,
        raw: { month: k, downloads: v },
      });
    }

    for (const ep of episodes) {
      const pub = ep.publish_at ? String(ep.publish_at) : "";
      const pubDay = pub ? chicagoDate(new Date(pub)) : "";
      if (!pubDay || pubDay < cutoff) continue;
      const eid = String(ep.podbean_episode_id);
      const epStats = await podbeanGet("/podcastStats/stats", accessToken, {
        episode_id: eid,
        start: windowStart,
        end: windowEnd,
        period: "d",
      }) as Json;
      const epMap = parseDateMap(epStats.stats ?? epStats.data ?? epStats);
      for (const [d, v] of Object.entries(epMap)) {
        if (d < windowStart || d > windowEnd) continue;
        metrics.push({
          metric_date: d,
          source_id: "podbean",
          episode_id: eid,
          metric: "downloads",
          value: v,
          raw: { episode_id: eid, date: d, downloads: v },
        });
      }
    }

    const payload = {
      window_start: windowStart,
      window_end: windowEnd,
      meta: {
        trigger: body.trigger ?? "manual",
        mode: body.mode ?? (body.start ? "manual" : "daily"),
        podcast_id: PODCAST_ID,
      },
      episodes,
      metrics,
      dims,
    };

    const { data: result, error: applyErr } = await supabase.rpc("ingest_apply", {
      p_job: "ingest-podbean",
      p_payload: payload,
    });
    if (applyErr) throw new Error(applyErr.message);

    return new Response(JSON.stringify(result), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    // Never include tokens in the message
    const safe = message.replace(/Bearer\s+\S+/gi, "Bearer [redacted]");
    await logFail(safe);
    return new Response(JSON.stringify({ error: safe }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    });
  }
});
