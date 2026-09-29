# hko-proxy

Updated: 2026-09-29

A Cloudflare Worker that serves the Hong Kong Observatory's weather for one station as **one small
JSON response**. The watch faces' HKO weather (`garmin/shared/source-weather/HkoService.mc`) calls
it every 10 minutes.

**Why it's needed.** HKO publishes its minute-level station readings (`latest_1min_temperature.csv`,
`latest_1min_humidity.csv`, `latest_10min_wind.csv`) as CSV with the Content-Type headers
`application/octet-stream` and `text/csv`. A Connect IQ request is relayed by Garmin Connect on the
phone, which only accepts a response whose Content-Type matches the requested type exactly, so a
watch can't read those files. The simulator skips that check, so there they appear to work. The
Worker reads them, plus HKO's hourly report (`rhrread`, for the icon) and warnings (`warnsum`), and
answers in `application/json`. That also cuts the watch's requests from five to one.

```
GET /hko?st=HK%20Park&hum=HK%20Park&wind=Central%20Pier&rhr=Hong%20Kong%20Park
→ {"t":29.7,"tt":1790674200,"h":82,"ht":1790674800,"ws":12,"wd":315,"wg":19,"wt":1790674800,
   "i":53,"it":1790659800,"w":["WHOT"],"wf":1790675270,"src":{"t":"min","h":"min","w":"min"}}
```

The keys are the ones the face stores (`Hko.mc`); times are epoch seconds. The station names come
from the watch's generated table (`garmin/shared/tools/hko_stations.py`), so this Worker holds no
station list. HKO's responses are cached at the edge for 60 s. If the Worker is down, the watch
falls back to requesting `rhrread` and `warnsum` from HKO directly (hourly readings, no HKO wind).

## Deploy

From this folder, with a Cloudflare account (the free plan is plenty: the faces make at most 144
calls a day per watch):

```bash
npx wrangler@4 login
npx wrangler@4 deploy
```

`deploy` prints the URL (`https://hko-proxy.<your-subdomain>.workers.dev`). The watch calls
`<that URL>/hko`: it's `PROXY_URL` in `garmin/shared/source-weather/HkoService.mc`, so a new
subdomain means changing that constant and rebuilding the faces.

## Test locally

```bash
npx wrangler@4 dev --port 8787
curl "http://127.0.0.1:8787/hko?st=HK%20Park&hum=HK%20Park&wind=Central%20Pier&rhr=Hong%20Kong%20Park"
```

Compare the values with the station's line in HKO's CSVs
(`https://data.weather.gov.hk/weatherAPI/hko_data/regional-weather/latest_1min_temperature.csv`).
