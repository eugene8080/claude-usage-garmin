/**
 * hko-proxy — a Cloudflare Worker that turns the Hong Kong Observatory's open data into ONE small
 * JSON response for one station, for the watch faces' HKO weather (garmin/shared/source-weather/
 * HkoService.mc).
 *
 * Why it exists: HKO's minute-level station feeds are CSV files served with the Content-Type
 * headers "application/octet-stream" and "text/csv". Connect IQ web requests go through Garmin
 * Connect on the phone, which only accepts a response whose Content-Type matches the requested
 * type exactly ("text/plain" for text, "application/json" for JSON), so a watch cannot read them.
 * The simulator skips that check, which is why they seemed to work there. This Worker reads the
 * CSVs (and the two JSON feeds the face also needs) and answers in plain "application/json". It
 * also cuts the watch's requests from five to one per fetch.
 *
 *   GET /hko?st=<temperature station>&hum=<humidity station>&wind=<wind station>&rhr=<rhrread name>
 *
 * Station names are spelled as in the feeds ("HK Park", "Central Pier"; rhrread says "Hong Kong
 * Park"); the watch's generated table (HkoStations.mc) supplies them. hum / wind default to st.
 *
 * Response: the same keys the face stores (Hko.mc), each group only when found:
 *   t  temperature °C     tt  its reading time (epoch s)    - latest_1min_temperature.csv
 *                                                            (falls back to rhrread, hourly)
 *   h  relative humidity  ht  its reading time             - latest_1min_humidity.csv
 *                                                            (falls back to rhrread: the Observatory)
 *   ws / wg  10-min mean wind / gust km/h, wd bearing it blows FROM (deg), wt  - latest_10min_wind.csv
 *   i  HKO weather icon code   it  its update time         - rhrread
 *   w  warning codes in force (cancelled ones dropped)  wf  when read  - warnsum
 *   src  {t,h,w: "min" | "hr"}: which feed each reading came from
 *
 * HKO's upstream responses are cached at Cloudflare's edge for 60 s, so this never asks HKO more
 * than once a minute per feed, however many watches call it.
 */

const CSV_BASE = "https://data.weather.gov.hk/weatherAPI/hko_data/regional-weather/";
const API_BASE = "https://data.weather.gov.hk/weatherAPI/opendata/weather.php";
const HKT_OFFSET_S = 8 * 3600; // HKO timestamps are Hong Kong Time, UTC+8, no daylight saving
const UPSTREAM_CACHE_S = 60;
const COMPASS = ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"];
// Station names are letters, spaces and apostrophes ("King's Park", "Tate's Cairn").
const NAME_RE = /^[A-Za-z' ]{2,40}$/;

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (request.method !== "GET" || url.pathname !== "/hko") {
      return json({ error: "not found" }, 404);
    }
    const st = name(url, "st");
    if (!st) {
      return json({ error: "st (a station name) is required" }, 400);
    }
    const hum = name(url, "hum") || st;
    const wind = name(url, "wind") || st;
    const rhr = name(url, "rhr");

    const [temp, humid, windCsv, report, warnings] = await Promise.allSettled([
      upstream(CSV_BASE + "latest_1min_temperature.csv", "text"),
      upstream(CSV_BASE + "latest_1min_humidity.csv", "text"),
      upstream(CSV_BASE + "latest_10min_wind.csv", "text"),
      upstream(API_BASE + "?dataType=rhrread&lang=en", "json"),
      upstream(API_BASE + "?dataType=warnsum&lang=en", "json"),
    ]);
    const out = {};
    const src = {};

    const tRow = csvRow(value(temp), st);
    if (tRow && isFinite(parseFloat(tRow.fields[0]))) {
      out.t = parseFloat(tRow.fields[0]);
      out.tt = tRow.when;
      src.t = "min";
    }
    const hRow = csvRow(value(humid), hum);
    if (hRow && isFinite(parseInt(hRow.fields[0], 10))) {
      const h = parseInt(hRow.fields[0], 10);
      if (h >= 0 && h <= 100) {
        out.h = h;
        out.ht = hRow.when;
        src.h = "min";
      }
    }
    // "<direction word>,<mean km/h>,<gust km/h>"; a calm or variable wind has no bearing, and
    // "N/A" in the speed means the station isn't reporting.
    const wRow = csvRow(value(windCsv), wind);
    if (wRow && isFinite(parseInt(wRow.fields[1], 10))) {
      out.ws = parseInt(wRow.fields[1], 10);
      out.wt = wRow.when;
      const k = COMPASS.indexOf(wRow.fields[0]);
      if (k >= 0) out.wd = k * 45;
      const g = parseInt(wRow.fields[2], 10);
      if (isFinite(g)) out.wg = g;
      src.w = "min";
    }

    const r = value(report);
    if (r && typeof r === "object") {
      if (Array.isArray(r.icon) && Number.isInteger(r.icon[0])) {
        out.i = r.icon[0];
        const it = isoEpoch(r.iconUpdateTime);
        if (it) out.it = it;
      }
      // Hourly fallbacks, used only when the minute feed had nothing for the station.
      if (out.t === undefined && rhr && r.temperature && Array.isArray(r.temperature.data)) {
        const row = r.temperature.data.find((d) => d && d.place === rhr);
        const when = isoEpoch(r.temperature.recordTime);
        if (row && typeof row.value === "number" && when) {
          out.t = row.value;
          out.tt = when;
          src.t = "hr";
        }
      }
      if (out.h === undefined && r.humidity && Array.isArray(r.humidity.data) && r.humidity.data[0]) {
        const v = r.humidity.data[0].value;
        const when = isoEpoch(r.humidity.recordTime);
        if (typeof v === "number" && v >= 0 && v <= 100 && when) {
          out.h = v;
          out.ht = when;
          src.h = "hr";
        }
      }
    }

    // warnsum: one entry per warning type in force. A just-cancelled warning can still be listed
    // with actionCode (or, for the typhoon signal, code) "CANCEL".
    const ws = value(warnings);
    if (ws && typeof ws === "object" && !Array.isArray(ws)) {
      out.w = Object.values(ws)
        .filter((x) => x && typeof x.code === "string" && x.code !== "CANCEL" && x.actionCode !== "CANCEL")
        .map((x) => x.code);
      out.wf = Math.floor(Date.now() / 1000);
    }

    out.src = src;
    return json(out, 200);
  },
};

function name(url, key) {
  const v = url.searchParams.get(key);
  return v && NAME_RE.test(v) ? v : null;
}

async function upstream(u, kind) {
  const res = await fetch(u, { cf: { cacheTtl: UPSTREAM_CACHE_S, cacheEverything: true } });
  if (!res.ok) throw new Error(`${u}: HTTP ${res.status}`);
  return kind === "json" ? res.json() : res.text();
}

function value(settled) {
  return settled.status === "fulfilled" ? settled.value : null;
}

/** The fields after `station` on its line of an HKO regional CSV, and the line's reading time. */
function csvRow(text, station) {
  if (typeof text !== "string" || !station) return null;
  for (const line of text.split("\n")) {
    const f = line.replace(/\r$/, "").split(",");
    if (f.length >= 3 && f[1] === station) {
      const when = stampEpoch(f[0]);
      return when ? { when, fields: f.slice(2) } : null;
    }
  }
  return null;
}

/** "202609291450" (HKT) -> epoch seconds. */
function stampEpoch(s) {
  const m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(s);
  if (!m) return null;
  return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) / 1000 - HKT_OFFSET_S;
}

/** "2026-09-29T13:30:00+08:00" -> epoch seconds. */
function isoEpoch(s) {
  const ms = typeof s === "string" ? Date.parse(s) : NaN;
  return isFinite(ms) ? Math.floor(ms / 1000) : null;
}

function json(body, status) {
  // Exactly "application/json": Connect IQ (via Garmin Connect) rejects any other type for a
  // JSON request.
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
