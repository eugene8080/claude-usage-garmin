import Toybox.Lang;
import Toybox.Position;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! Data 08's second time zone. Each city is a coordinate, not a fixed UTC offset: the time is
//! resolved with Gregorian.localMoment, which applies that location's time zone INCLUDING daylight
//! saving, so the clock stays right year-round with nothing to maintain. UTC is the one entry
//! with no location and is read from Gregorian.utcInfo instead.
//!
//! LAT / LON / names() share one index, which is also the AltTzCity property value and the
//! settings.xml listEntry value - keep all four in the same order.
module AltTz {

    const LAT = [40.7128, 41.8781, 34.0522, 51.5074, 48.8566, 47.3769, 25.2048, 19.0760,
                 1.3521, 22.3193, 31.2304, 35.6762, -33.8688, -36.8485, 0.0];
    const LON = [-74.0060, -87.6298, -118.2437, -0.1278, 2.3522, 8.5417, 55.2708, 72.8777,
                 103.8198, 114.1694, 121.4737, 139.6503, 151.2093, 174.7633, 0.0];
    const UTC_INDEX = 14;

    //! City labels for the on-watch menu (the phone settings use the same string ids).
    function names() as Array<ResourceId> {
        return [Rez.Strings.tzNewYork, Rez.Strings.tzChicago, Rez.Strings.tzLosAngeles,
                Rez.Strings.tzLondon, Rez.Strings.tzParis, Rez.Strings.tzZurich,
                Rez.Strings.tzDubai, Rez.Strings.tzMumbai, Rez.Strings.tzSingapore,
                Rez.Strings.tzHongKong, Rez.Strings.tzShanghai, Rez.Strings.tzTokyo,
                Rez.Strings.tzSydney, Rez.Strings.tzAuckland, Rez.Strings.tzUtc];
    }

    //! Clamp a stored property value to a valid index (a stale or hand-edited value can't crash).
    function clampIndex(v as Object or Null) as Number {
        if (v instanceof Lang.Number && (v as Number) >= 0 && (v as Number) < LAT.size()) {
            return v as Number;
        }
        return 0;
    }

    //! "HH:MM" (24 h, zero-padded) in the chosen zone; "--:--" if the platform can't resolve it.
    function timeStr(index as Number) as String {
        try {
            var info;
            if (index == UTC_INDEX) {
                info = Gregorian.utcInfo(Time.now(), Time.FORMAT_SHORT);
            } else {
                var loc = new Position.Location({
                    :latitude => LAT[index], :longitude => LON[index], :format => :degrees
                });
                var lm = Gregorian.localMoment(loc, Time.now());
                if (lm == null) { return "--:--"; }
                info = Gregorian.info(lm, Time.FORMAT_SHORT);
            }
            return info.hour.format("%02d") + ":" + info.min.format("%02d");
        } catch (ex) {
            return "--:--";
        }
    }
}
