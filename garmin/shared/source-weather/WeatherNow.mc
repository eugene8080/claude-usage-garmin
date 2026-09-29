import Toybox.Complications;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.Time;
import Toybox.Weather;

//! The weather both faces show as "now", with an offline fallback to the stored hourly forecast.
//!
//! With an HKO station set (the HkoStation setting), the Hong Kong Observatory's station readings
//! come first - see Hko.mc; everything described below is the Garmin path used when they don't.
//!
//! Garmin's current conditions reach the watch only while the phone is connected (Garmin Connect
//! relays them). Weather.getCurrentConditions() returns the most recently CACHED observation, so
//! with the phone away it keeps returning the last one synced, however old. That same sync also
//! leaves an hourly forecast on the watch (12 hours of it in the simulator). Once the observation
//! is stale, this reads the forecast for the current hour instead and flags the reading, so the
//! faces can mark it ("~31°"):
//!
//!   observation not stale (see below)      -> the observation (what the faces always showed)
//!   stale, a forecast hour within 30 min   -> that forecast hour, forecast = true
//!   stale, no forecast hour covers now     -> the observation until MAX_AGE_SEC, then null
//!
//! "Stale" depends on the phone link. Garmin's observationTime routinely sits 1-2 hours old on a
//! CONNECTED watch (it refreshes about hourly, and the observation lags the refresh; the
//! simulator's own canned reading is 95 minutes old), so a single short cut-off would flip a
//! connected watch to the forecast between syncs. Connected, the observation is trusted until
//! STALE_LINKED_SEC - past that the sync has stopped even though the link is up (e.g. the phone
//! froze Garmin Connect). With the phone gone nothing will refresh it, so it goes stale at
//! STALE_ALONE_SEC.
//!
//! The hourly forecast carries no feels-like temperature, so a forecast Reading's feelsLike is
//! null. Garmin's own complications (the high/low, the temperature complication) are not touched:
//! only the values the faces compute themselves go through here.
//!
//! isNight() picks the sun or moon icon. It reads the watch's own sunrise / sunset, not the
//! observation's location: see the note on isNight for why.
module WeatherNow {

    //! Phone connected: the observation counts as stale past this age.
    const STALE_LINKED_SEC = 10800;   // 3 h
    //! Phone not connected: the observation counts as stale past this age.
    const STALE_ALONE_SEC = 3600;     // 1 h
    //! With no forecast hour left, a stale observation is still shown up to this age; past it the
    //! faces show no weather rather than a reading from hours ago.
    const MAX_AGE_SEC = 10800;        // 3 h
    //! The forecast hour nearest now is used when it is at most this far away. The entries are an
    //! hour apart, so any time the forecast spans has one within 30 minutes.
    const HOUR_SLACK_SEC = 1800;   // 30 min

    //! One weather reading, in the Weather API's units. Any field may be null (not reported).
    class Reading {
        public var condition as Number or Null = null;           // a Weather.CONDITION_* value
        public var temperature as Numeric or Null = null;        // Celsius
        public var feelsLike as Numeric or Null = null;          // Celsius; always null for a forecast
        public var humidity as Number or Null = null;            // relative humidity, 0-100 %
        public var precipChance as Number or Null = null;        // chance of precipitation, 0-100 %
        public var windSpeed as Float or Null = null;            // m/s
        public var windBearing as Number or Null = null;         // degrees the wind comes FROM, N = 0
        // Where observed. Garmin's readings always leave this null here, because the faces don't
        // hold the Positioning permission. The sun / moon icon uses isNight(), not this.
        public var location as Position.Location or Null = null;
        public var forecast as Boolean = false;                  // true = the hourly-forecast fallback

        public function initialize() {
        }
    }

    // The forecast lookup walks the whole hourly array, so its result is kept for the current
    // minute: the faces ask more than once per redraw (Claude Grid once per weather slot), and
    // Claude Terminal redraws every second while the watch is awake. Only the stale path uses it,
    // so a fresh observation arriving mid-minute is shown at once.
    var _fcMinute as Number = -1;
    var _fc as Reading or Null = null;

    //! The reading to show now, or null when the watch has no usable weather.
    function get() as Reading or Null {
        var cc = null;
        try {
            cc = Weather.getCurrentConditions();
        } catch (e) {
            cc = null;
        }
        // Hong Kong Observatory first, when a station is set and its reading is recent (Hko.mc);
        // everything below is the Garmin path, used otherwise.
        var hko = Hko.reading(cc);
        if (hko != null) {
            return hko;
        }
        var now = Time.now().value();
        var age = null;
        if (cc != null && cc.observationTime != null) {
            age = now - (cc.observationTime as Moment).value();
        }
        var staleAt = System.getDeviceSettings().phoneConnected ? STALE_LINKED_SEC : STALE_ALONE_SEC;
        // Fresh, or undated (no way to tell its age, so it is shown as before).
        if (cc != null && (age == null || (age as Number) <= staleAt)) {
            return fromCurrent(cc);
        }

        var minute = now / 60;
        if (minute != _fcMinute) {
            _fcMinute = minute;
            _fc = forecastAt(now, (cc != null) ? cc.observationLocationPosition : null);
        }
        if (_fc != null) {
            return _fc;
        }
        // Past the forecast (or none was synced): a stale observation is still better than
        // nothing for a while. `age` is set here - an undated observation returned above.
        if (cc != null && (age as Number) <= MAX_AGE_SEC) {
            return fromCurrent(cc);
        }
        return null;
    }

    //! A Reading from Garmin's current conditions.
    function fromCurrent(cc as Weather.CurrentConditions) as Reading {
        var r = new Reading();
        r.condition = cc.condition;
        r.temperature = cc.temperature;
        r.feelsLike = cc.feelsLikeTemperature;
        r.humidity = cc.relativeHumidity;
        r.precipChance = cc.precipitationChance;
        r.windSpeed = cc.windSpeed;
        r.windBearing = cc.windBearing;
        r.location = cc.observationLocationPosition;
        return r;
    }

    //! The stored hourly forecast's entry nearest `now` (epoch seconds), as a forecast Reading, or
    //! null when there is no forecast or none of its hours is within HOUR_SLACK_SEC of now. `loc`
    //! is the last observation's location, since forecast entries carry none.
    function forecastAt(now as Number, loc as Position.Location or Null) as Reading or Null {
        var hours = null;
        try {
            hours = Weather.getHourlyForecast();
        } catch (e) {
            hours = null;
        }
        if (hours == null) {
            return null;
        }
        var best = null;
        var bestGap = HOUR_SLACK_SEC + 1;
        for (var i = 0; i < hours.size(); i++) {
            var hf = hours[i];
            if (hf == null || hf.forecastTime == null) {
                continue;
            }
            var gap = (hf.forecastTime as Moment).value() - now;
            if (gap < 0) {
                gap = -gap;
            }
            if (gap < bestGap) {
                best = hf;
                bestGap = gap;
            }
        }
        if (best == null) {
            return null;
        }
        var r = new Reading();
        r.condition = best.condition as Number or Null;
        r.temperature = best.temperature;
        r.humidity = best.relativeHumidity;
        r.precipChance = best.precipitationChance;
        r.windSpeed = best.windSpeed;
        r.windBearing = best.windBearing;
        r.location = loc;
        r.forecast = true;
        return r;
    }

    // isNight() runs on every redraw that draws a weather icon (Claude Terminal redraws every
    // second while the watch is awake). Sunrise and sunset move by a minute or two a day, so the
    // answer is kept for the current minute, like the forecast lookup above.
    var _nightMinute as Number = -1;
    var _night as Boolean = false;

    //! True between sunset and the next sunrise: the faces then draw the moon variant of the clear
    //! and partly-cloudy icons.
    //!
    //! The sun times are the watch's own SUNRISE / SUNSET complications (the times Garmin's faces
    //! show, for the watch's last known position), read on demand without subscribing. The faces
    //! already hold ComplicationSubscriber for the Claude meters, so this needs no new permission.
    //! Weather.getSunrise/getSunset need a Position.Location, and every location a face can read
    //! is null without the Positioning permission: CurrentConditions.observationLocationPosition,
    //! Activity.Info.currentLocation, and Position.getInfo() (which the compiler rejects outright).
    //! Checked in the simulator on 2026-09-29.
    //!
    //! No sun times (polar day or night, a watch that has never had a position) -> daytime. The
    //! sun icons are the safer default.
    function isNight() as Boolean {
        var minute = Time.now().value() / 60;
        if (minute != _nightMinute) {
            _nightMinute = minute;
            var rise = sunSeconds(Complications.COMPLICATION_TYPE_SUNRISE);
            var set = sunSeconds(Complications.COMPLICATION_TYPE_SUNSET);
            var clock = System.getClockTime();
            var now = clock.hour * 3600 + clock.min * 60 + clock.sec;
            _night = rise != null && set != null && nightAt(now, rise as Number, set as Number);
        }
        return _night;
    }

    //! The day/night test itself. All three arguments are seconds since local midnight.
    //!
    //! Daytime is the span from `rise` forward to `set`, taken on a 24-hour circle. It wraps past
    //! midnight when rise > set, which happens when the watch's clock zone is not the zone of its
    //! position. The simulator does this: an HKT clock with an Olathe position gives rise 20:11,
    //! set 08:08. Working on the circle also means it doesn't matter whether a complication
    //! reports today's time or the next one, since the two differ by a minute or two.
    function nightAt(now as Number, rise as Number, set as Number) as Boolean {
        if (rise == set) {
            return false;   // no span to test against
        }
        if (rise < set) {
            return now < rise || now >= set;
        }
        return now >= set && now < rise;
    }

    //! A SUNRISE / SUNSET complication's value in seconds since local midnight, or null when the
    //! watch has none or reports something that is not a time of day.
    function sunSeconds(type as Complications.Type) as Number or Null {
        var v = null;
        try {
            v = Complications.getComplication(new Complications.Id(type)).value;
        } catch (e) {
            return null;   // ComplicationNotFoundException: the device has no such complication
        }
        if (!(v instanceof Lang.Number || v instanceof Lang.Float
              || v instanceof Lang.Double || v instanceof Lang.Long)) {
            return null;
        }
        var s = v.toNumber();
        return (s >= 0 && s < 86400) ? s : null;
    }
}
