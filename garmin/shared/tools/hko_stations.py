"""Generate the HKO (Hong Kong Observatory) station table the faces use for local weather.

Run from anywhere:  python garmin/shared/tools/hko_stations.py

The faces read HKO's minute-level station feeds (garmin/shared/source-weather/HkoService.mc):

    latest_1min_temperature.csv   39 stations   temperature, every minute
    latest_1min_humidity.csv      26 stations   relative humidity, every minute
    latest_10min_wind.csv         30 stations   10-minute mean wind, every 10 minutes

The user picks ONE station (the HkoStation setting); temperature comes from it. Humidity and wind
come from the same station when it reports them, otherwise from the nearest station that does -
nearest by great-circle distance, never a hilltop station (Tate's Cairn, Ngong Ping, Tai Mo Shan,
The Peak: > 300 m) for somewhere else, since hilltop wind and humidity are nothing like street
level. The hourly `rhrread` report is the fallback for temperature if the minute feed can't be
read, under its own spelling of the name ("Hong Kong Park" vs the CSV's "HK Park").

Station ids are PERMANENT: the setting stores the id, so a watch keeps its station across
versions. Append new stations with the next free id; never renumber. Id 0 = off (Garmin weather).

Coordinates: HKO "Information of Weather Station" (https://www.hko.gov.hk/en/cis/stn.htm,
read 2026-09-29), except where marked approximate.

Writes (all generated - edit this script, not them):
    garmin/shared/source-weather/HkoStations.mc      the background table (feed names per id)
    garmin/shared/source-weather/HkoNames.mc          the menu order + name resources (foreground)
    garmin/shared/resources-hko/strings/hko_strings.xml
    garmin/shared/resources-hko/settings/hko_properties.xml
    garmin/shared/resources-hko/settings/hko_settings.xml
"""
from __future__ import annotations

import math
import re
from pathlib import Path

SHARED = Path(__file__).resolve().parent.parent          # garmin/shared
SRC = SHARED / "source-weather"
RES = SHARED / "resources-hko"

# --- coordinates: name as the feeds spell it -> (lat, lon, elevation m) ---------------------------
def dms(s: str) -> float:
    d, m, sec = (int(x) for x in re.findall(r"\d+", s))
    return d + m / 60 + sec / 3600

# Every station any of the three feeds (or rhrread) names. Stations whose feed name differs from
# the HKO table name carry the table name in the comment.
COORDS: dict[str, tuple[str, str, int]] = {
    "Chek Lap Kok":               ("22°18'34\"", "113°55'19\"", 6),    # Hong Kong International Airport (HKA)
    "Cheung Chau":                ("22°12'04\"", "114°01'36\"", 72),
    "Clear Water Bay":            ("22°15'48\"", "114°17'59\"", 66),
    "Happy Valley":               ("22°16'14\"", "114°11'01\"", 5),
    "HK Observatory":             ("22°18'07\"", "114°10'27\"", 32),   # Hong Kong Observatory (HKO)
    "HK Park":                    ("22°16'42\"", "114°09'44\"", 26),   # Hong Kong Park (HKP)
    "Kai Tak Runway Park":        ("22°18'18\"", "114°13'01\"", 4),
    "Kau Sai Chau":               ("22°22'13\"", "114°18'45\"", 39),
    "King's Park":                ("22°18'43\"", "114°10'22\"", 65),
    "Kowloon City":               ("22°20'06\"", "114°11'05\"", 92),
    "Kwun Tong":                  ("22°19'07\"", "114°13'29\"", 90),
    "Lau Fau Shan":               ("22°28'08\"", "113°59'01\"", 31),
    "Ngong Ping":                 ("22°15'31\"", "113°54'46\"", 593),
    "Pak Tam Chung":              ("22°24'10\"", "114°19'23\"", 5),    # Pak Tam Chung (Tsak Yue Wu) (TYW)
    "Peng Chau":                  ("22°17'28\"", "114°02'36\"", 34),
    "Sai Kung":                   ("22°22'32\"", "114°16'28\"", 4),
    "Sha Tin":                    ("22°24'09\"", "114°12'36\"", 6),
    "Sham Shui Po":               ("22°20'09\"", "114°08'13\"", 11),
    "Shau Kei Wan":               ("22°16'54\"", "114°14'10\"", 53),
    "Shek Kong":                  ("22°26'10\"", "114°05'05\"", 16),
    "Sheung Shui":                ("22°30'07\"", "114°06'40\"", 10),
    "Stanley":                    ("22°12'51\"", "114°13'07\"", 31),
    "Ta Kwu Ling":                ("22°31'43\"", "114°09'24\"", 15),
    "Tai Lung":                   ("22°29'05\"", "114°07'03\"", 21),
    "Tai Mei Tuk":                ("22°28'31\"", "114°14'15\"", 51),
    "Tai Mo Shan":                ("22°24'38\"", "114°07'28\"", 955),
    "Tai Po":                     ("22°26'54\"", "114°10'38\"", 6),    # Tai Po (Yuen Chau Tsai Park) (YCT)
    "Tate's Cairn":               ("22°21'28\"", "114°13'04\"", 572),
    "The Peak":                   ("22°15'51\"", "114°09'18\"", 406),
    "Tseung Kwan O":              ("22°18'57\"", "114°15'20\"", 38),
    "Tsing Yi":                   ("22°20'39\"", "114°06'36\"", 8),    # New Tsing Yi Station (TY1)
    "Tsuen Wan Ho Koon":          ("22°23'01\"", "114°06'28\"", 142),  # Tsuen Wan (TWN)
    "Tsuen Wan Shing Mun Valley": ("22°22'32\"", "114°07'36\"", 35),
    "Tuen Mun":                   ("22°23'09\"", "113°57'51\"", 28),   # Tuen Mun Children and Juvenile Home (TU1)
    "Waglan Island":              ("22°10'56\"", "114°18'12\"", 56),
    "Wetland Park":               ("22°28'00\"", "114°00'32\"", 4),
    "Wong Chuk Hang":             ("22°14'52\"", "114°10'25\"", 5),
    "Wong Tai Sin":               ("22°20'22\"", "114°12'19\"", 21),
    "Yuen Long Park":             ("22°26'27\"", "114°01'06\"", 8),
}
# Wind-feed stations that are not temperature stations, or are a different instrument under the
# same name. Keyed by the wind CSV's spelling.
WIND_COORDS: dict[str, tuple[str, str, int]] = {
    "Central Pier":         ("22°17'20\"", "114°09'21\"", 19),
    "Cheung Chau Beach":    ("22°12'39\"", "114°01'45\"", 27),
    "Green Island":         ("22°17'06\"", "114°06'46\"", 88),
    "Hong Kong Sea School": ("22°13'11\"", "114°12'47\"", 20),    # APPROXIMATE: not in the HKO table; the school is in Stanley
    "Kai Tak":              ("22°18'35\"", "114°12'48\"", 3),     # Kai Tak (SE)
    "Lamma Island":         ("22°13'34\"", "114°06'31\"", 7),
    "North Point":          ("22°17'40\"", "114°11'59\"", 26),
    "Sha Chau":             ("22°20'45\"", "113°53'28\"", 31),
    "Star Ferry":           ("22°17'35\"", "114°10'07\"", 18),    # Star Ferry (Kowloon) (SF)
    "Tai Po Kau":           ("22°26'33\"", "114°11'02\"", 12),
    "Tap Mun":              ("22°28'06\"", "114°21'47\"", 48),    # Tap Mun East (TME)
    "Tsing Yi":             ("22°20'48\"", "114°05'11\"", 43),    # Shell Oil Depot (SHL), the Tsing Yi wind station
    "Tuen Mun":             ("22°23'26\"", "113°58'36\"", 69),    # Tuen Mun Government Offices (TUN)
}

# --- the feeds' station lists (2026-09-29) ------------------------------------------------------
TEMP = ["Chek Lap Kok", "Cheung Chau", "Clear Water Bay", "Happy Valley", "HK Observatory", "HK Park",
        "Kai Tak Runway Park", "Kau Sai Chau", "King's Park", "Kowloon City", "Kwun Tong",
        "Lau Fau Shan", "Ngong Ping", "Pak Tam Chung", "Peng Chau", "Sai Kung", "Sha Tin",
        "Sham Shui Po", "Shau Kei Wan", "Shek Kong", "Sheung Shui", "Stanley", "Ta Kwu Ling",
        "Tai Lung", "Tai Mei Tuk", "Tai Mo Shan", "Tai Po", "Tate's Cairn", "The Peak",
        "Tseung Kwan O", "Tsing Yi", "Tsuen Wan Ho Koon", "Tsuen Wan Shing Mun Valley", "Tuen Mun",
        "Waglan Island", "Wetland Park", "Wong Chuk Hang", "Wong Tai Sin", "Yuen Long Park"]
HUMIDITY = ["Chek Lap Kok", "Cheung Chau", "Clear Water Bay", "HK Observatory", "HK Park",
            "Kai Tak Runway Park", "Kau Sai Chau", "King's Park", "Kowloon City", "Lau Fau Shan",
            "Pak Tam Chung", "Peng Chau", "Sai Kung", "Sha Tin", "Shau Kei Wan", "Shek Kong",
            "Sheung Shui", "Ta Kwu Ling", "Tai Lung", "Tai Po", "Tseung Kwan O", "Tsing Yi",
            "Tuen Mun", "Waglan Island", "Wetland Park", "Wong Chuk Hang"]
WIND = ["Central Pier", "Chek Lap Kok", "Cheung Chau", "Cheung Chau Beach", "Green Island",
        "Hong Kong Sea School", "Kai Tak", "King's Park", "Lamma Island", "Lau Fau Shan", "Ngong Ping",
        "North Point", "Peng Chau", "Sai Kung", "Sha Chau", "Sha Tin", "Shek Kong", "Stanley",
        "Star Ferry", "Ta Kwu Ling", "Tai Mei Tuk", "Tai Po Kau", "Tap Mun", "Tate's Cairn",
        "Tseung Kwan O", "Tsing Yi", "Tuen Mun", "Waglan Island", "Wetland Park", "Wong Chuk Hang"]
# rhrread's temperature list, under rhrread's own names (27 of the 39).
RHRREAD = {"HK Observatory": "Hong Kong Observatory", "HK Park": "Hong Kong Park"}
RHRREAD_SAME = {"King's Park", "Wong Chuk Hang", "Ta Kwu Ling", "Lau Fau Shan", "Tai Po", "Sha Tin",
                "Tuen Mun", "Tseung Kwan O", "Sai Kung", "Cheung Chau", "Chek Lap Kok", "Tsing Yi",
                "Shek Kong", "Tsuen Wan Ho Koon", "Tsuen Wan Shing Mun Valley", "Shau Kei Wan",
                "Kowloon City", "Happy Valley", "Wong Tai Sin", "Stanley", "Kwun Tong", "Sham Shui Po",
                "Kai Tak Runway Park", "Yuen Long Park", "Tai Mei Tuk"}

# Menu names where the feed's abbreviation reads badly on the watch.
DISPLAY = {"HK Park": "Hong Kong Park", "HK Observatory": "HK Observatory (TST)",
           "Chek Lap Kok": "Chek Lap Kok (Airport)"}

# PERMANENT ids (see the module docstring). Append only.
IDS = {name: i + 1 for i, name in enumerate(TEMP)}
DEFAULT = "HK Park"
HILLTOP_M = 300


def km(a: tuple[str, str, int], b: tuple[str, str, int]) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (dms(a[0]), dms(a[1]), dms(b[0]), dms(b[1])))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 6371.0 * 2 * math.asin(math.sqrt(h))


def nearest(name: str, pool: list[str], coords: dict[str, tuple[str, str, int]]) -> str:
    """`name` itself when it is in the pool, else the nearest non-hilltop pool station."""
    if name in pool:
        return name
    here = COORDS[name]
    best = min((p for p in pool if coords[p][2] <= HILLTOP_M), key=lambda p: km(here, coords[p]))
    return best


def mc_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> None:
    assert len(set(IDS.values())) == len(IDS) and 0 not in IDS.values()
    wind_coords = {**COORDS, **WIND_COORDS}          # wind names shadow same-named temp stations
    for n in TEMP + HUMIDITY:
        assert n in COORDS, n
    for n in WIND:
        assert n in wind_coords, n

    n_ids = max(IDS.values()) + 1
    temp = [""] * n_ids
    hum = [""] * n_ids
    wind = [""] * n_ids
    rhr = [""] * n_ids
    rows = []
    for name, sid in IDS.items():
        temp[sid] = name
        hum[sid] = nearest(name, HUMIDITY, COORDS)
        # Wind: a station's own anemometer only when the wind feed's same-named station is the
        # same place (Tsing Yi and Tuen Mun are different instruments, a few km away - still the
        # nearest, which is what `nearest` finds from the temp station's own coordinates).
        wind[sid] = nearest(name, WIND, wind_coords) if name not in WIND_COORDS else \
            min((p for p in WIND if wind_coords[p][2] <= HILLTOP_M), key=lambda p: km(COORDS[name], wind_coords[p]))
        rhr[sid] = RHRREAD.get(name, name if name in RHRREAD_SAME else "")
        rows.append((sid, name, hum[sid], wind[sid], rhr[sid]))

    SRC.mkdir(parents=True, exist_ok=True)
    body = []
    body.append("import Toybox.Application;")
    body.append("import Toybox.Lang;")
    body.append("")
    body.append("// GENERATED by garmin/shared/tools/hko_stations.py - edit that script, not this file.")
    body.append("//")
    body.append("//! The HKO station table, indexed by the PERMANENT station id the HkoStation setting stores")
    body.append("//! (0 = off: Garmin weather only). For each station: its name in the minute temperature feed,")
    body.append("//! the humidity and wind feeds' station to read with it (itself, or the nearest one that")
    body.append("//! reports that element), and its name in the hourly rhrread report (\"\" when rhrread has no")
    body.append("//! temperature for it). Background-annotated: the fetch runs in the background service.")
    body.append("(:background)")
    body.append("module HkoStations {")
    body.append("")
    body.append("    //! The setting's default: Hong Kong Park.")
    body.append("    const DEFAULT_ID = %d;" % IDS[DEFAULT])
    for label, arr in (("TEMP", temp), ("HUM", hum), ("WIND", wind), ("RHR", rhr)):
        body.append("")
        body.append("    const %s = [" % label)
        for sid in range(n_ids):
            body.append("        %s,%s" % (mc_str(arr[sid]), ("   // %d" % sid)))
        body.append("    ] as Array<String>;")
    body.append("")
    body.append("    //! The selected station id, clamped (a hand-edited or stale value falls back to the default;")
    body.append("    //! 0 stays 0 = off).")
    body.append("    function selected() as Number {")
    body.append("        var v = Application.Properties.getValue(\"HkoStation\");")
    body.append("        if (v instanceof Lang.Number && (v as Number) >= 0 && (v as Number) < TEMP.size()) {")
    body.append("            return v as Number;")
    body.append("        }")
    body.append("        return DEFAULT_ID;")
    body.append("    }")
    body.append("}")
    (SRC / "HkoStations.mc").write_text("\n".join(body) + "\n", encoding="utf-8")

    # Menu order: "Off" first, then the stations alphabetically by display name.
    order = sorted(IDS.items(), key=lambda kv: DISPLAY.get(kv[0], kv[0]).lower())
    names = []
    names.append("import Toybox.Lang;")
    names.append("")
    names.append("// GENERATED by garmin/shared/tools/hko_stations.py - edit that script, not this file.")
    names.append("//")
    names.append("//! The station picker's rows: ids in menu order (Off first, then A-Z by name) and the")
    names.append("//! matching name resources (garmin/shared/resources-hko).")
    names.append("module HkoNames {")
    names.append("")
    names.append("    const IDS = [0, %s] as Array<Number>;" % ", ".join(str(sid) for _, sid in order))
    names.append("")
    names.append("    function names() as Array<ResourceId> {")
    names.append("        return [Rez.Strings.hkoSt0, %s] as Array<ResourceId>;"
                 % ", ".join("Rez.Strings.hkoSt%d" % sid for _, sid in order))
    names.append("    }")
    names.append("}")
    (SRC / "HkoNames.mc").write_text("\n".join(names) + "\n", encoding="utf-8")

    def xml_esc(s: str) -> str:
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    (RES / "strings").mkdir(parents=True, exist_ok=True)
    (RES / "settings").mkdir(parents=True, exist_ok=True)
    s = ["<!-- GENERATED by garmin/shared/tools/hko_stations.py - edit that script, not this file. -->",
         "<strings>",
         '    <string id="hkoStationTitle">HKO weather station</string>',
         '    <string id="hkoSt0">Off (Garmin weather)</string>']
    for name, sid in sorted(IDS.items(), key=lambda kv: kv[1]):
        s.append('    <string id="hkoSt%d">%s</string>' % (sid, xml_esc(DISPLAY.get(name, name))))
    s.append("</strings>")
    (RES / "strings" / "hko_strings.xml").write_text("\n".join(s) + "\n", encoding="utf-8")

    p = ["<!-- GENERATED by garmin/shared/tools/hko_stations.py - edit that script, not this file. -->",
         "<properties>",
         "    <!-- HKO station id (HkoStations.mc; ids are permanent). 0 = off: Garmin weather only. -->",
         '    <property id="HkoStation" type="number">%d</property>' % IDS[DEFAULT],
         "</properties>"]
    (RES / "settings" / "hko_properties.xml").write_text("\n".join(p) + "\n", encoding="utf-8")

    st = ["<!-- GENERATED by garmin/shared/tools/hko_stations.py - edit that script, not this file. -->",
          "<settings>",
          '    <setting propertyKey="@Properties.HkoStation" title="@Strings.hkoStationTitle">',
          '        <settingConfig type="list">',
          '            <listEntry value="0">@Strings.hkoSt0</listEntry>']
    for name, sid in order:
        st.append('            <listEntry value="%d">@Strings.hkoSt%d</listEntry>' % (sid, sid))
    st += ["        </settingConfig>", "    </setting>", "</settings>"]
    (RES / "settings" / "hko_settings.xml").write_text("\n".join(st) + "\n", encoding="utf-8")

    width = max(len(r[1]) for r in rows)
    for sid, name, h, w, r in sorted(rows):
        print("%2d  %-*s  hum: %-20s wind: %-20s rhrread: %s" % (sid, width, name, h, w, r or "-"))


if __name__ == "__main__":
    main()
