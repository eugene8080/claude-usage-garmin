# Generates the self-contained Claude Grid complication editor (v4).
import base64, os
from io import BytesIO
from PIL import Image, ImageFont, ImageDraw

TTF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "tabler-icons.ttf")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-grid-editor.html")
GRAY = (158, 158, 158, 255)
font = ImageFont.truetype(TTF, 88)

def icon_datauri(cp):
    img = Image.new("RGBA", (104, 104), (0, 0, 0, 0))
    d = ImageDraw.Draw(img); ch = chr(cp)
    bb = d.textbbox((0, 0), ch, font=font); w, h = bb[2]-bb[0], bb[3]-bb[1]
    d.text(((104-w)/2-bb[0], (104-h)/2-bb[1]), ch, font=font, fill=GRAY)
    buf = BytesIO(); img.save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

def composite_datauri(back_cp):
    """Cloud with a small sun/moon behind it - the face's partly-cloudy icon (cg_icon 0xE001/2,
    built the same way in ../tools/build_fonts_grid.py): the cloud silhouette plus a moat is
    cut out of the back glyph so the two outlines never touch."""
    import numpy as np
    from scipy.ndimage import binary_dilation, binary_fill_holes
    S = 104
    def layer(size, cp, dx, dy):
        f = ImageFont.truetype(TTF, size)
        im = Image.new("L", (S, S), 0)
        ImageDraw.Draw(im).text((dx, dy), chr(cp), font=f, fill=255)
        return np.asarray(im).astype(np.float64) / 255.0
    cloud = layer(int(88 * 0.86), 0xea76, 4, 24)
    back = layer(int(88 * 0.62), back_cp, 46, 4)
    body = binary_fill_holes(cloud > 0.35)
    cut = binary_dilation(body, iterations=4)
    a = np.maximum(cloud, np.where(cut, 0.0, back))
    rgba = np.zeros((S, S, 4), dtype=np.uint8)
    rgba[..., 0], rgba[..., 1], rgba[..., 2] = GRAY[0], GRAY[1], GRAY[2]
    rgba[..., 3] = np.round(a * 255).astype(np.uint8)
    buf = BytesIO(); Image.fromarray(rgba, "RGBA").save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

# Every icon the face can draw (ClaudeGridView.iconCodeFor / weatherGlyph), incl. the ones added
# 2026-09-25: run / bike (VO2 max), trending-up (training status), lungs (respiration),
# thermometer (current temperature).
CPS = [0xea34,0xec87,0xef92,0xea38,0xef62,0xeab1,0xeb38,0xec2c,0xeca5,0xef97,
       0xf0db,0xea97,0xff9b,0xea35,0xef1c,0xec31,0xea76,0xeaf8,0xf228,0xeb30,
       0xea72,0xea73,0xea74,0xecd9,0xec34,0xec0b,0x10265,0xea04,0xeb54,
       0xec82,0xea36,0xeb43]
ICONS = {("0x%x" % cp): icon_datauri(cp) for cp in CPS}
ICONS["cloudsun"] = composite_datauri(0xeb30)
icons_js = "{" + ",".join('"%s":"%s"' % (k, v) for k, v in ICONS.items()) + "}"

# Font menu, grouped by style so it's navigable. Every face has FIXED-WIDTH DIGITS (so the time never
# jitters); all are on Google Fonts. The dot-matrix group was checked 2026-09-25 (loads + ten equal
# digit widths); rejected there for proportional digits: Pixelify Sans, Micro 5, Jersey 10-25,
# Jacquard 12/24, Rubik Pixels, Bitcount Prop Single/Double. (Silkscreen's digits vary slightly but
# it was already in the list.)
FONT_GROUPS = [
 ("Modern / neo-grotesque", ["Chivo Mono","Geist Mono","Reddit Mono","Fragment Mono","Commit Mono",
   "DM Mono","Red Hat Mono","Spline Sans Mono","Martian Mono","Azeret Mono","Roboto Mono"]),
 ("Coding / humanist", ["JetBrains Mono","Fira Code","Fira Mono","Source Code Pro","IBM Plex Mono",
   "Inconsolata","Ubuntu Mono","Ubuntu Sans Mono","Noto Sans Mono","Oxygen Mono","Cousine","PT Mono",
   "Nanum Gothic Coding","Anonymous Pro","Victor Mono"]),
 ("Technical / squared", ["Share Tech Mono","Kode Mono","B612 Mono","Space Mono","Overpass Mono",
   "Lekton","Nova Mono"]),
 ("Typewriter / serif", ["Courier Prime","Cutive Mono","Xanh Mono"]),
 ("Display / novelty", ["Major Mono Display","Syne Mono","Monofett"]),
 ("Dot matrix / pixel / LED", ["Doto","Handjet","Bitcount Grid Double","Bitcount Grid Single",
   "Bitcount Grid Double Ink","Bitcount Single","Bitcount Single Ink","Bitcount","DotGothic16",
   "Press Start 2P","Tiny5","Workbench","Sixtyfour","Sixtyfour Convergence","VT323","Silkscreen"]),
]
_all = [f for _, fs in FONT_GROUPS for f in fs]
assert len(_all) == len(set(_all)), "a font is listed in two groups"
font_groups_js = "[" + ",".join('["%s",[%s]]' % (g, ",".join('"%s"' % f for f in fs))
                                for g, fs in FONT_GROUPS) + "]"
HTML = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Grid - editor</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link id="gf-JetBrains-Mono" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@600&display=swap" rel="stylesheet">
<style>
  body{margin:0;background:#141414;color:#ddd;font-family:ui-sans-serif,Segoe UI,Roboto,sans-serif;display:flex;gap:22px;padding:18px;flex-wrap:wrap;}
  h1{font-size:15px;color:#F2A98C;margin:0 0 4px;} p.hint{color:#8a8a8a;font-size:12px;margin:0 0 10px;max-width:470px;line-height:1.5;}
  canvas{border-radius:50%;box-shadow:0 0 0 10px #2a2a2a,0 0 0 12px #000;touch-action:none;cursor:grab;display:block;}
  /* Centre-line ticks on the grey bezel ring (the canvas box-shadow): 2 px white marks
     at 12 / 3 / 6 / 9 o'clock so the vertical and horizontal centre lines are visible.
     Outside the canvas and click-through, so they never affect drawing or hit tests. */
  .dial{position:relative;display:inline-block;}
  .dial .tk{position:absolute;background:#fff;pointer-events:none;}
  .tk.t{left:calc(50% - 1px);top:-10px;width:2px;height:10px;}
  .tk.b{left:calc(50% - 1px);bottom:-10px;width:2px;height:10px;}
  .tk.l{top:calc(50% - 1px);left:-10px;width:10px;height:2px;}
  .tk.r{top:calc(50% - 1px);right:-10px;width:10px;height:2px;}
  .side{flex:1 1 340px;min-width:320px;max-width:450px;}
  .panel{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:10px;padding:12px 15px;margin-bottom:12px;}
  .panel h2{font-size:13px;color:#E95625;margin:0 0 10px;text-transform:uppercase;letter-spacing:.5px;}
  .row{display:flex;align-items:center;gap:10px;margin:8px 0;font-size:12.5px;color:#bbb;}
  .row label{flex:0 0 92px;color:#999;} .row input[type=range]{flex:1;}
  .row .val{flex:0 0 42px;text-align:right;color:#F2A98C;font-family:ui-monospace,monospace;}
  select,input[type=color]{background:#0c0c0c;color:#ddd;border:1px solid #333;border-radius:6px;padding:4px;font-family:inherit;font-size:12.5px;} select{flex:1;}
  input.hex{width:78px;background:#0c0c0c;color:#ddd;border:1px solid #333;border-radius:6px;padding:4px;font-family:ui-monospace,monospace;font-size:12px;}
  button{background:#E95625;color:#111;border:0;border-radius:8px;padding:8px 14px;font-family:inherit;font-weight:bold;cursor:pointer;margin:6px 8px 0 0;} button.sec{background:#333;color:#ddd;}
  textarea{width:100%;height:150px;background:#0c0c0c;border:1px solid #333;border-radius:8px;padding:10px;font-family:ui-monospace,monospace;font-size:11.5px;color:#bfe7d8;}
  .muted{color:#666;font-size:11.5px;} .chk{display:flex;gap:7px;align-items:center;}
</style></head>
<body>
  <div>
    <h1>Claude Grid - complication editor</h1>
    <p class="hint"><b>Click</b> a field (or the top arc) to select it. Set its <b>complication</b> and
      sizes; <b>drag</b> to move (snaps to align) or nudge with the <b>arrow keys</b> (Shift = 10 px); <b>Tab</b> / <b>Shift+Tab</b> selects the next / previous.
      Colours take <b>hex</b>. <b>Copy</b> the block back to me.</p>
    <div class="dial"><canvas id="c" width="454" height="454"></canvas><i class="tk t"></i><i class="tk r"></i><i class="tk b"></i><i class="tk l"></i></div>
  </div>
  <div class="side">
    <div class="panel">
      <div class="row"><label style="flex:0 0 40px">Font</label><select id="fontSel"></select></div>
      <div class="row chk"><input type="checkbox" id="snap" checked><label style="flex:0 0 auto">Snap to align (vertical + horizontal)</label></div>
      <div class="row chk"><input type="checkbox" id="mir" checked><label style="flex:0 0 auto">Mirror left/right (position + sizes)</label></div>
      <div class="row chk"><input type="checkbox" id="lowp"><label style="flex:0 0 auto">Low-power preview (always-on mode)</label></div>
      <div class="row chk"><input type="checkbox" id="vfd"><label style="flex:0 0 auto" title="Test face I: glowing bitmap time + one mesh over the whole face">VFD style (glow time + full-face mesh)</label></div>
    </div>
    <div class="panel">
      <h2>Preview time &amp; date</h2>
      <div class="row"><label>Hour</label><input type="range" id="pvH" min="0" max="23" step="1"><span class="val" id="pvHV"></span></div>
      <div class="row"><label>Minute</label><input type="range" id="pvM" min="0" max="59" step="1"><span class="val" id="pvMV"></span></div>
      <div class="row"><label>Second</label><input type="range" id="pvS" min="0" max="59" step="1"><span class="val" id="pvSV"></span></div>
      <div class="row"><label>Day</label><input type="range" id="pvD" min="1" max="31" step="1"><span class="val" id="pvDV"></span></div>
      <div class="row"><label>Month</label><input type="range" id="pvMo" min="1" max="12" step="1"><span class="val" id="pvMoV"></span></div>
      <div class="row chk"><input type="checkbox" id="pv24" checked><label style="flex:0 0 auto">24-hour</label><button class="sec" id="pvNow" style="margin:0 0 0 auto">Now</button></div>
      <div class="muted">Drives the time, seconds dial, date, weekday highlight and the Data 08 clock. Preview only - not part of the settings block.</div>
    </div>
    <div class="panel">
      <h2>Selected: <span id="selName">- none -</span></h2>
      <div id="ctlComp" class="row" style="display:none"><label>Complication</label><select id="compSel"></select></div>
      <div id="ctlRing" class="row" style="display:none"><label>Ring radius</label><input type="range" id="ringR" min="15" max="110" step="1"><span class="val" id="ringRV"></span></div>
      <div id="ctlNum" class="row" style="display:none"><label id="numLbl">Number px</label><input type="range" id="numR" min="8" max="120" step="1"><span class="val" id="numRV"></span></div>
      <div id="ctlSym" class="row" style="display:none"><label>Symbol px</label><input type="range" id="symR" min="8" max="80" step="1"><span class="val" id="symRV"></span></div>
      <div id="ctlGap" class="row" style="display:none"><label>HH/MM gap</label><input type="range" id="gapR" min="20" max="110" step="1"><span class="val" id="gapRV"></span></div>
      <div id="ctlFade" class="row" style="display:none"><label>Time fade</label><input type="range" id="fadeR" min="0" max="1" step="0.02"><span class="val" id="fadeRV"></span></div>
      <div id="ctlText" class="row" style="display:none"><label>Text</label><input type="text" id="brandT" style="flex:1;background:#0c0c0c;color:#ddd;border:1px solid #333;border-radius:6px;padding:5px;font-family:inherit;font-size:12.5px"></div>
      <div id="ctlDGap" class="row" style="display:none"><label>Month/day gap</label><input type="range" id="dgapR" min="20" max="180" step="1"><span class="val" id="dgapRV"></span></div>
      <div id="ctlWeek" class="row" style="display:none"><label>Week width</label><input type="range" id="wspanR" min="40" max="130" step="1"><span class="val" id="wspanRV"></span></div>
      <div id="ctlArcR" class="row" style="display:none"><label>Arc radius</label><input type="range" id="aradR" min="120" max="228" step="1"><span class="val" id="aradRV"></span></div>
      <div id="ctlArcSpan" class="row" style="display:none"><label>Arc width</label><input type="range" id="aspanR" min="30" max="150" step="1"><span class="val" id="aspanRV"></span></div>
      <div id="ctlArcW" class="row" style="display:none"><label>Dash width</label><input type="range" id="adwR" min="1" max="10" step="0.5"><span class="val" id="adwRV"></span></div>
      <div id="ctlArcL" class="row" style="display:none"><label>Dash length</label><input type="range" id="adlR" min="4" max="28" step="1"><span class="val" id="adlRV"></span></div>
      <div id="ctlTick" class="row" style="display:none"><label>Tick style</label><select id="tickSel"><option value="2px">2 px straight</option><option value="3px">3 px straight</option><option value="taper">Tapered 3 &rarr; 2 px</option></select></div>
      <div id="ctlKnock" class="row" style="display:none"><label title="black gap cut around the dial, into the minute digits">Knockout gap</label><input type="range" id="knockR" min="0" max="16" step="1"><span class="val" id="knockRV"></span></div>
      <div id="ctlCity" class="row" style="display:none"><label>Time zone</label><select id="citySel"></select></div>
      <div id="ctlNone" class="muted">Click a field on the watch to edit it.</div>
    </div>
    <div class="panel">
      <h2>Watch colours</h2>
      <div class="row"><label title="sets every colour below at once; editing any colour switches to Custom">Theme</label><select id="themeSel"></select></div>
      <div class="row"><label>Accent</label><input type="color" id="cAcc"><input type="text" id="cAccH" class="hex"></div>
      <div class="row"><label title="most values">Text 1</label><input type="color" id="cT1"><input type="text" id="cT1H" class="hex"></div>
      <div class="row"><label title="Data 04/05 + date">Text 2</label><input type="color" id="cT2"><input type="text" id="cT2H" class="hex"></div>
      <div class="row"><label title="icons, SEC, weekdays">Text 3</label><input type="color" id="cT3"><input type="text" id="cT3H" class="hex"></div>
      <div class="row"><label title="hour digits (solid)">Hour</label><input type="color" id="cHc"><input type="text" id="cHcH" class="hex"></div>
      <div class="row"><label title="ring/arc gradient start">Gradient 1</label><input type="color" id="cG1"><input type="text" id="cG1H" class="hex"></div>
      <div class="row"><label title="ring/arc gradient end">Gradient 2</label><input type="color" id="cG2"><input type="text" id="cG2H" class="hex"></div>
      <div class="row"><label title="VFD style: halo around the hour digits">Hour glow</label><input type="color" id="cHg"><input type="text" id="cHgH" class="hex"></div>
      <div class="row"><label title="VFD style: halo around the minute digits">Minute glow</label><input type="color" id="cMg"><input type="text" id="cMgH" class="hex"></div>
    </div>
    <div class="panel">
      <h2>Settings (paste back to me)</h2>
      <textarea id="out" readonly></textarea>
      <button onclick="copyOut()">Copy settings</button><button class="sec" onclick="reset()">Reset</button>
    </div>
  </div>
<script>
const ICONS=__ICONS__, FONT_GROUPS=__FONT_GROUPS__;
const IMG={}; let ready=0, total=Object.keys(ICONS).length;
for(const k in ICONS){ const im=new Image(); im.onload=()=>{ready++; if(ready>=total) draw();}; im.src=ICONS[k]; IMG[k]=im; }
function img(cp){ return typeof cp==="string" ? IMG[cp] : IMG["0x"+cp.toString(16)]; }
const SZ=454, cx=SZ/2, cy=SZ/2; let GA=[181,80,47], GB=[255,192,138]; const DIM="#9a9a9a", TRACK="#333333";  // neutral dark grey track (= GridDraw.TRACK), theme-independent
// What the face actually draws for each type (ClaudeGridView.updateSlotText, 2026-09-25):
// icon = cg_icon glyph, v = sample value, lb = label shown when there's no icon,
// bare = value only (no icon, no label), stack = high/low on two right-aligned lines.
// ORDER IS STABLE - saved layouts store the index - so new types are only ever appended.
const COMPS=[
 {k:"Battery",ic:0xea34,v:"50%",lb:"BAT"},{k:"Steps",ic:0x10265,v:"8420",lb:"STEPS"},
 {k:"Heart Rate",ic:0xef92,v:"72",lb:"HR"},{k:"Body Battery",ic:0xea38,v:"64",lb:"BODY"},
 {k:"VO2 Max Run",ic:0xec82,v:"52",lb:"VO2"},{k:"Pressure",ic:null,v:"1013",lb:"HPA"},
 {k:"Current Temp",ic:0xeb38,v:"29°",lb:""},{k:"High/Low Temp",ic:null,v:"29°/27°",lb:"",stack:true},
 {k:"Calories",ic:0xec2c,v:"1240",lb:"CAL"},{k:"Floors",ic:0xeca5,v:"12",lb:"FLR"},
 {k:"Altitude",ic:0xef97,v:"340",lb:"ALT"},{k:"Stress",ic:0xf0db,v:"28",lb:"STR"},
 {k:"Pulse Ox",ic:0xea97,v:"98",lb:"SPO2"},{k:"Intensity Min",ic:0xff9b,v:"45",lb:"INT"},
 {k:"Notifications",ic:0xea35,v:"3",lb:"NOTIF"},{k:"Sunrise",ic:0xef1c,v:"6:12",lb:"RISE"},
 {k:"Sunset",ic:0xec31,v:"18:18",lb:"SET"},{k:"Current Weather",ic:"cloudsun",v:"29°",lb:""},
 {k:"Sleep Score",ic:0xeaf8,v:"82",lb:"SLP"},{k:"Recovery",ic:0xf228,v:"18",lb:"REC"},
 {k:"Solar",ic:0xeb30,v:"45",lb:"SOL"},{k:"Seconds",ic:null,v:"38",lb:"SEC",sec:true},
 {k:"Claude 5-hour",ic:null,v:"42%",lb:"5H"},{k:"Claude weekly",ic:null,v:"63%",lb:"1W"},
 {k:"Claude Fable",ic:null,v:"55%",lb:"FABLE"},
 {k:"Alt Time Zone",ic:0xeb54,v:"",lb:"",tz:true},
 {k:"VO2 Max Bike",ic:0xea36,v:"48",lb:"VO2"},{k:"Training Status",ic:0xeb43,v:"PROD",lb:""},
 {k:"Respiration",ic:0xef62,v:"14",lb:"RESP"},{k:"Day of Week",ic:null,v:"FRI 25",lb:"",bare:true},
 {k:"Date",ic:null,v:"SEP 25",lb:"",bare:true},{k:"Quote Glance",ic:null,v:"227.52",lb:"QUOTE"},
];
// Data 08's time-zone clock cities (AltTz.mc order), with their IANA zones for a live preview.
const CITIES=[["New York","America/New_York"],["Chicago","America/Chicago"],["Los Angeles","America/Los_Angeles"],
 ["London","Europe/London"],["Paris","Europe/Paris"],["Zurich","Europe/Zurich"],["Dubai","Asia/Dubai"],
 ["Mumbai","Asia/Kolkata"],["Singapore","Asia/Singapore"],["Hong Kong","Asia/Hong_Kong"],["Shanghai","Asia/Shanghai"],
 ["Tokyo","Asia/Tokyo"],["Sydney","Australia/Sydney"],["Auckland","Pacific/Auckland"],["UTC","UTC"]];
// Preview clock: every time/date the face shows is drawn from PV, set by the "Preview time & date"
// sliders (starts at the real now). Formats follow the face: hour "%02d" (12 h -> 01-12),
// minute/second "%02d", date "SEP" + "19", weekday highlight = that date's day of week.
const MONTHS=["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"];
let PV;
function pvNow(){ const n=new Date(); PV={h:n.getHours(),m:n.getMinutes(),s:n.getSeconds(),day:n.getDate(),mon:n.getMonth()+1,year:n.getFullYear(),h24:PV?PV.h24:true}; }
pvNow();
function pad2(v){ return (v<10?"0":"")+v; }
function daysIn(){ return new Date(PV.year,PV.mon,0).getDate(); }
function previewDate(){ return new Date(PV.year,PV.mon-1,PV.day,PV.h,PV.m,PV.s); }
function HH(){ let h=PV.h; if(!PV.h24){ h=h%12; if(h==0) h=12; } return pad2(h); }
function MM(){ return pad2(PV.m); }
function DD(){ return ""+PV.day; }
function MON(){ return MONTHS[PV.mon-1]; }
// Data 08's clock: the PREVIEW moment shown in that city's zone (so it moves with the sliders).
function tzTime(city){ const z=(CITIES.find(c=>c[0]==city)||CITIES[0])[1];
  try{ return new Intl.DateTimeFormat("en-GB",{timeZone:z,hour:"2-digit",minute:"2-digit",hour12:false}).format(previewDate()); }catch(e){ return "--:--"; } }
function valueOf(e,c){ return c ? (c.tz ? tzTime(e.city) : c.v) : ""; }
const SEC_IDX=21;
// Defaults = the face as built (2026-09-25): Roboto Mono, teal VFD, the layout pasted from this
// editor. Arc radius 224 = the face's (screen radius 227 - 3); the old 228 ran past the screen edge.
function defaults(){return {font:"IBM Plex Mono",accent:"#fede5d",text1:"#36f9f6",text2:"#ffffff",text3:"#848bbd",hourCol:"#ffffff",grad1:"#ff7edb",grad2:"#f97e72",
  hourGlow:"#ff7edb",minGlow:"#fc28a8",   // VFD glow colours (build_glow_digits.py --hour-glow / --minute-glow)
  vfd:true, theme:"synthwave",
  arc:{span:65,dashW:10,dashLen:15,frac:0.5,rad:227},
  el:{
  batt:{name:"Data 01 (battery)",kind:"horiz",x:0.500,y:0.092,comp:24,num:24,sym:24},
  d02:{name:"Data 02 (upper-left)",kind:"chip",x:0.175,y:0.299,comp:7,num:30,sym:24},
  d03:{name:"Data 03 (upper-right)",kind:"chip",x:0.825,y:0.299,comp:1,num:30,sym:24},
  d04:{name:"Data 04 (left ring)",kind:"ring",x:0.139,y:0.500,comp:22,ring:56,num:36,sym:24,frac:0.53},
  d05:{name:"Data 05 (right ring)",kind:"ring",x:0.861,y:0.500,comp:23,ring:56,num:36,sym:24,frac:0.72},
  d06:{name:"Data 06 (lower-left)",kind:"chip",x:0.177,y:0.722,comp:17,num:30,sym:24},
  d08:{name:"Data 08 (lower-right)",kind:"chip",x:0.823,y:0.722,comp:25,num:30,sym:24,city:"New York"},
  sec:{name:"Data 07 (seconds dial)",kind:"tick",x:0.500,y:0.832,comp:SEC_IDX,ring:50,num:30,sym:24,frac:0.63,tick:"2px",knock:5},
  time:{name:"Time",kind:"time",x:0.500,y:0.477,gap:59,num:153,fade:0.44},
  brand:{name:"Brand text",kind:"brand",x:0.500,y:0.169,num:36,text:"TACTIX"},
  alarmi:{name:"Alarm indicator",kind:"ind",x:0.166,y:0.169,sym:22,ic:0xea04},
  swatch:{name:"Stopwatch indicator",kind:"ind",x:0.834,y:0.169,sym:22,ic:0xff9b},
  date:{name:"Date",kind:"date",x:0.500,y:0.832,num:37,gap:90},
  week:{name:"Week",kind:"week",x:0.500,y:0.971,num:27,span:52},
}};}
let P=defaults(), sel=null, guide=null, boxes={}, lowPower=false;
const PAIR={d02:"d03",d03:"d02",d04:"d05",d05:"d04",d06:"d08",d08:"d06"};
function mirror(k){ if(!document.getElementById("mir").checked)return; const q=PAIR[k]; if(!q)return; const a=P.el[k],b=P.el[q]; b.x=1-a.x; b.y=a.y; if(a.ring!=null)b.ring=a.ring; if(a.num!=null)b.num=a.num; if(a.sym!=null)b.sym=a.sym; }
const ctx=document.getElementById("c").getContext("2d"), out=document.getElementById("out");
// Watch-faithful text placement. The face draws its text TEXT_JUSTIFY_VCENTER: CIQ puts the line
// top at y - floor(lineHeight / 2) and the glyph baseline at line top + font ascent + 1 row (the
// +1 measured in the simulator). The canvas "middle" baseline puts text ~4 px higher than that, so
// every "middle" fillText is re-based here with the canvas font metrics (which equal the TTF
// metrics the watch fonts were generated from). The time digits are placed by their ink instead
// (TimeInk.DY on the face, inkDy() here) and bypass this via rawFill.
const rawFill=ctx.fillText.bind(ctx);
ctx.fillText=function(s,x,y,mw){
  if(ctx.textBaseline!=="middle") return mw===undefined?rawFill(s,x,y):rawFill(s,x,y,mw);
  // measure AFTER switching to the alphabetic baseline: fontBoundingBox* are relative to the
  // current textBaseline, so under "middle" they are not the font's ascent/descent at all.
  ctx.textBaseline="alphabetic"; const m=ctx.measureText(s), A=m.fontBoundingBoxAscent, D=m.fontBoundingBoxDescent;
  rawFill(s,x,Math.round(y)-Math.floor((A+D)/2)+A+1); ctx.textBaseline="middle"; };
function lerp(a,b,t){return `rgb(${Math.round(a[0]+(b[0]-a[0])*t)},${Math.round(a[1]+(b[1]-a[1])*t)},${Math.round(a[2]+(b[2]-a[2])*t)})`;}
function num(px){return px+"px '"+P.font+"',monospace";}
function hexRgb(h){ h=(h||"#000000").replace("#",""); return [parseInt(h.slice(0,2),16)||0,parseInt(h.slice(2,4),16)||0,parseInt(h.slice(4,6),16)||0]; }
const _tc=document.createElement("canvas"); _tc.width=160; _tc.height=160; const _tcx=_tc.getContext("2d");
function tintIcon(im,x,y,s,color){ _tcx.clearRect(0,0,160,160); _tcx.drawImage(im,0,0,s,s); _tcx.globalCompositeOperation="source-in"; _tcx.fillStyle=color; _tcx.fillRect(0,0,s,s); _tcx.globalCompositeOperation="source-over"; ctx.drawImage(_tc,0,0,s,s,x-s/2,y-s/2,s,s); }
function ring(x,y,r,pen,frac,striped){ ctx.lineWidth=pen; ctx.strokeStyle=TRACK; ctx.beginPath(); ctx.arc(x,y,r,0,2*Math.PI); ctx.stroke();
  const steps=36,lit=Math.round(steps*frac); for(let i=0;i<lit;i++){ if(striped&&i%2==0)continue; ctx.strokeStyle=lerp(GA,GB,i/steps);
    ctx.beginPath(); ctx.arc(x,y,r,-Math.PI/2+i*2*Math.PI/steps,-Math.PI/2+(i+1)*2*Math.PI/steps); ctx.stroke(); } }
// Seconds ticks as filled square-ended quads (the face's pre-rasterised cg_ticks font): 2 px or
// 3 px straight, or tapered 3 px (outer) -> 2 px (inner). Odd outer widths sit on a pixel centre,
// even ones on a pixel corner, exactly like tools/build_tick_font.py, so 12/3/6/9 stay crisp.
function tickRing(x,y,r,frac,style){ const n=60,lit=Math.round(n*frac),len=9;
  const wo=style=="2px"?2:3, wi=style=="taper"?2:wo, off=(wo%2)?0.5:0; const X=x+off, Y=y+off, ro=r+off, ri=ro-len;
  for(let i=0;i<n;i++){ const a=-Math.PI/2+i*2*Math.PI/n,c=Math.cos(a),s=Math.sin(a),px=-s,py=c;
    ctx.fillStyle=i<lit?lerp(GA,GB,i/n):TRACK; ctx.beginPath();
    ctx.moveTo(X+ro*c+px*wo/2,Y+ro*s+py*wo/2); ctx.lineTo(X+ro*c-px*wo/2,Y+ro*s-py*wo/2);
    ctx.lineTo(X+ri*c-px*wi/2,Y+ri*s-py*wi/2); ctx.lineTo(X+ri*c+px*wi/2,Y+ri*s+py*wi/2); ctx.closePath(); ctx.fill(); } }
// The VFD mesh (resources-mesh): every third screen row and column darkened 30%, one lattice for
// the whole face. A 3x3 pattern tile so intersections are darkened once, as on the watch.
const _mesh=document.createElement("canvas"); _mesh.width=3; _mesh.height=3;
{ const m=_mesh.getContext("2d"), d=m.createImageData(3,3); for(let yy=0;yy<3;yy++) for(let xx=0;xx<3;xx++){ const o=(yy*3+xx)*4; d.data[o+3]=(xx==2||yy==2)?77:0; } m.putImageData(d,0,0); }
function meshOverlay(){ ctx.fillStyle=ctx.createPattern(_mesh,"repeat"); ctx.fillRect(0,0,SZ,SZ); }
function battArc(){ const a=P.arc, r=a.rad, n=16, lit=Math.round(n*a.frac), st=90+a.span/2, en=90-a.span/2; ctx.lineWidth=a.dashW;
  for(let i=0;i<n;i++){ const ang=(st-(st-en)*i/(n-1))*Math.PI/180, c=Math.cos(ang), s=Math.sin(ang);
    ctx.strokeStyle=i<lit?lerp(GA,GB,i/n):TRACK; ctx.beginPath(); ctx.moveTo(cx+r*c,cy-r*s); ctx.lineTo(cx+(r-a.dashLen)*c,cy-(r-a.dashLen)*s); ctx.stroke(); }
}
// Time digits are placed by their INK centre (actualBoundingBox), not the canvas "middle"
// baseline - "middle" puts each font's digits at a different height (Roboto Mono 8.6 px high).
// The face does the same with its generated TimeInk.DY, so the two agree for any typeface.
function inkDy(){ const m=ctx.measureText("0123456789"); return (m.actualBoundingBoxAscent-m.actualBoundingBoxDescent)/2; }
function tabular(str,x,y,f,color){ ctx.font=f; ctx.textAlign="center"; ctx.textBaseline="middle"; y+=inkDy(); let cw=0;
  for(let d=0;d<=9;d++) cw=Math.max(cw,ctx.measureText(""+d).width); const sx=x-str.length*cw/2;
  for(let i=0;i<str.length;i++){ ctx.fillStyle=color; rawFill(str[i],sx+cw*(i+0.5),y); } }
// Always-on outline time: 2 px, like the face's regenerated cg_time_o (was ~5.5 px here).
function tabularStroke(str,x,y,f,color){ ctx.font=f; ctx.textAlign="center"; ctx.textBaseline="middle"; y+=inkDy(); ctx.lineWidth=2; let cw=0; for(let d=0;d<=9;d++) cw=Math.max(cw,ctx.measureText(""+d).width); const sx=x-str.length*cw/2; for(let i=0;i<str.length;i++){ ctx.strokeStyle=color; ctx.strokeText(str[i],sx+cw*(i+0.5),y); } }
function symbol(e,x,y){ const c=COMPS[e.comp], s=e.sym;
  if(c && c.bare) return;
  if(c && c.ic!=null){ const im=img(c.ic); if(im&&im.complete) tintIcon(im,x,y,s,P.text3); return; }
  ctx.fillStyle=P.text3; ctx.font=num(Math.round(s*0.72)); ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText(c?c.lb:"",x,y); }
function drawEl(k){ const e=P.el[k], x=e.x*SZ, y=e.y*SZ, c=COMPS[e.comp]; ctx.textAlign="center"; ctx.textBaseline="middle";
  if(e.kind=="time"){ const f=num(e.num); const mmy=y+e.gap, topY=mmy-e.num*0.42, botY=mmy+e.num*0.42; const g=ctx.createLinearGradient(0,topY,0,botY); const fw=Math.max(0.001,e.fade); g.addColorStop(0,P.grad1); g.addColorStop(Math.max(0,0.5-fw*0.5),P.grad1); g.addColorStop(Math.min(1,0.5+fw*0.5),P.grad2); g.addColorStop(1,P.grad2); if(lowPower){ tabularStroke(HH(),x,y-e.gap,f,P.hourCol); tabularStroke(MM(),x,mmy,f,g); }
    else if(P.vfd){ // glow digits (resources-glow-vfd): peach bloom on the hour, orange-red on the minute
      const hg=hexRgb(P.hourGlow), mg=hexRgb(P.minGlow);
      ctx.save(); ctx.shadowBlur=16; ctx.shadowColor="rgba("+hg.join(",")+",0.85)"; tabular(HH(),x,y-e.gap,f,P.hourCol);
      ctx.shadowColor="rgba("+mg.join(",")+",0.9)"; tabular(MM(),x,mmy,f,g); ctx.restore(); }
    else { tabular(HH(),x,y-e.gap,f,P.hourCol); tabular(MM(),x,mmy,f,g); } boxes[k]=[x-e.num*0.62,y-e.gap-e.num*0.42,x+e.num*0.62,y+e.gap+e.num*0.42]; return; }
  if(e.kind=="brand"){ ctx.fillStyle=P.text3; ctx.font=num(e.num); ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText(e.text,x,y); boxes[k]=[x-70,y-18,x+70,y+18]; return; }
  if(e.kind=="ind"){ const im=img(e.ic); if(im&&im.complete) tintIcon(im,x,y,e.sym,P.text3); boxes[k]=[x-e.sym/2-5,y-e.sym/2-5,x+e.sym/2+5,y+e.sym/2+5]; return; }
  if(e.kind=="date"){ if(lowPower){ ctx.fillStyle=P.text2; ctx.font=num(Math.round(e.num*0.85)); ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText(DD(),x,y-e.num*0.42); ctx.fillText(MON(),x,y+e.num*0.42); boxes[k]=[x-40,y-e.num*0.85,x+40,y+e.num*0.85]; return; } const d=e.gap; ctx.fillStyle=P.text2; ctx.font=num(e.num); ctx.fillText(MON(),x-d,y); ctx.fillText(DD(),x+d,y); boxes[k]=[x-d-42,y-24,x+d+42,y+24]; return; }
  if(e.kind=="week"){ const R=y-cy, sp=e.span, st=90+sp/2; ctx.font=num(e.num);
    for(let i=0;i<7;i++){ const th=(st-(sp/6)*i)*Math.PI/180, lx=cx+R*Math.cos(th), ly=cy+R*Math.sin(th);
      ctx.save(); ctx.translate(lx,ly); ctx.rotate(th-Math.PI/2); ctx.fillStyle=i==previewDate().getDay()?P.accent:P.text3; ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText("SMTWTFS"[i],0,0); ctx.restore(); }
    boxes[k]=[cx-110,y-26,cx+110,y+18]; return; }
  const isSec=c&&c.sec;
  if(e.kind=="tick"){ if(lowPower) return; const rr=e.ring; tickRing(x,y,rr,isSec?PV.s/60:e.frac,e.tick||"2px"); symbol(e,x,y-rr*0.5);
    ctx.fillStyle=isSec?P.accent:P.text1; ctx.font=num(e.num); ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText(isSec?pad2(PV.s):valueOf(e,c),x,y+e.num*0.3); boxes[k]=[x-rr-4,y-rr-4,x+rr+4,y+rr+4]; return; }
  if(e.kind=="ring"){ const rr=e.ring; if(!lowPower) ring(x,y,rr,6,e.frac,false); symbol(e,x,y-rr*0.42);
    ctx.fillStyle=P.text2; ctx.font=num(e.num); ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText(valueOf(e,c),x,y+e.num*0.28); boxes[k]=[x-rr-4,y-rr-4,x+rr+4,y+rr+4]; return; }
  if(e.kind=="horiz"){ const hv=valueOf(e,c); ctx.font=num(e.num); const vw=ctx.measureText(hv).width; let iw=0, lbl=null;
    if(c.ic!=null){ iw=e.sym; } else { lbl=c.lb; ctx.font=num(Math.round(e.sym*0.72)); iw=ctx.measureText(lbl).width; ctx.font=num(e.num); }
    const gap=iw>0?7:0, tot=iw+gap+vw, sx=x-tot/2;
    if(c.ic!=null){ const im=img(c.ic); if(im&&im.complete) tintIcon(im,sx+e.sym/2,y,e.sym,P.text3); }
    else if(lbl){ ctx.fillStyle=P.text3; ctx.textAlign="left"; ctx.textBaseline="middle"; ctx.font=num(Math.round(e.sym*0.72)); ctx.fillText(lbl,sx,y); }
    ctx.fillStyle=P.text1; ctx.textAlign="left"; ctx.textBaseline="middle"; ctx.font=num(e.num); ctx.fillText(hv,sx+iw+gap,y); ctx.textAlign="center"; boxes[k]=[x-tot/2-6,y-e.num*0.7,x+tot/2+6,y+e.num*0.7]; return; }
  if(!(c&&c.stack)) symbol(e,x,y-e.sym-4); ctx.textAlign="center"; ctx.textBaseline="middle";
  if(c&&c.stack){ // high/low: two lines on ONE right edge, no divider (ClaudeGridSlot stacked branch)
    const p=c.v.split("/"), fs=Math.round(e.num*0.8), dy=e.num*0.4; ctx.font=num(fs); ctx.fillStyle=P.text1;
    const wmax=Math.max(ctx.measureText(p[0]).width,ctx.measureText(p[1]||"").width), right=x+wmax/2;
    ctx.textAlign="right"; ctx.fillText(p[0],right,y-dy); ctx.fillText(p[1]||"",right,y+dy); ctx.textAlign="center"; }
  else { ctx.fillStyle=P.text1; ctx.font=num(e.num); ctx.fillText(valueOf(e,c),x,y); }
  boxes[k]=[x-46,y-38,x+46,y+38];
}
// Same order as ClaudeGridView.onUpdate: arc, slots, time, brand, indicators, THEN the knockout
// disc (so it cuts only the digits), then dial/date and week on top, and the mesh last of all.
function knockout(){ const s=P.el.sec; ctx.fillStyle="#000"; ctx.beginPath(); ctx.arc(s.x*SZ,s.y*SZ,s.ring+(s.knock||0),0,2*Math.PI); ctx.fill(); }
function draw(){ lowPower=document.getElementById("lowp").checked; P.vfd=document.getElementById("vfd").checked; ctx.fillStyle="#000"; ctx.fillRect(0,0,SZ,SZ); boxes={}; GA=hexRgb(P.grad1); GB=hexRgb(P.grad2); battArc();
  ["batt","d02","d03","d04","d05","d06","d08","time","brand","alarmi","swatch"].forEach(drawEl);
  knockout();
  ["sec","date","week"].forEach(drawEl);
  if(P.vfd && !lowPower) meshOverlay();
  if(sel=="arc"){ const a=P.arc, hs=a.span/2*Math.PI/180; ctx.strokeStyle="#E95625"; ctx.lineWidth=1; ctx.setLineDash([4,3]); ctx.beginPath(); ctx.arc(cx,cy,a.rad+5,-Math.PI/2-hs,-Math.PI/2+hs); ctx.stroke(); ctx.beginPath(); ctx.arc(cx,cy,a.rad-a.dashLen-5,-Math.PI/2-hs,-Math.PI/2+hs); ctx.stroke(); ctx.setLineDash([]); }
  else if(sel&&boxes[sel]){ const b=boxes[sel]; ctx.strokeStyle="#E95625"; ctx.lineWidth=1; ctx.setLineDash([4,3]); ctx.strokeRect(b[0],b[1],b[2]-b[0],b[3]-b[1]); ctx.setLineDash([]); }
  if(guide){ ctx.strokeStyle="#39d98a"; ctx.lineWidth=1; ctx.setLineDash([3,3]);
    if(guide.x!=null){ ctx.beginPath(); ctx.moveTo(guide.x,0); ctx.lineTo(guide.x,SZ); ctx.stroke(); }
    if(guide.y!=null){ ctx.beginPath(); ctx.moveTo(0,guide.y); ctx.lineTo(SZ,guide.y); ctx.stroke(); } ctx.setLineDash([]); }
  refresh();
}
function hit(mx,my){ let best=null,bd=1e9;
  { const a=P.arc, dx=mx-cx, dy=my-cy, dist=Math.hypot(dx,dy), ang=Math.atan2(dx,-dy)*180/Math.PI, band=Math.max(16,a.dashLen+8);
    if(Math.abs(dist-(a.rad-a.dashLen/2))<band && Math.abs(ang)<=a.span/2+5){ best="arc"; bd=0; } }
  for(const k in boxes){ if(k=="arc")continue; const b=boxes[k], ix=Math.max(b[0],Math.min(mx,b[2])), iy=Math.max(b[1],Math.min(my,b[3])); const d=(mx-ix)**2+(my-iy)**2; if(d<bd){bd=d;best=k;} } return bd<42*42?best:null; }
function snapAxis(val,others){ let best=val,g=null,bd=0.014; const t=[0.5].concat(others); for(const o of t){ if(Math.abs(val-o)<bd){ bd=Math.abs(val-o); best=o; g=o*SZ; } } return [best,g]; }
let drag=null; const cv=document.getElementById("c");
cv.addEventListener("pointerdown",ev=>{ if(document.activeElement&&document.activeElement!==document.body) document.activeElement.blur(); // arrows -> watch, not the last dropdown
  const r=cv.getBoundingClientRect(), mx=(ev.clientX-r.left)*SZ/r.width, my=(ev.clientY-r.top)*SZ/r.height; const k=hit(mx,my);
  if(k){ sel=k; drag=k; cv.setPointerCapture(ev.pointerId); cv.style.cursor="grabbing"; syncPanel(); draw(); } else deselect(); });
// Clicking away from the watch - its empty areas (above), or anywhere on the page outside the
// settings panel - drops the selection and its orange frame. The panel keeps it: its controls
// edit the selected element. Esc does the same (keydown handler).
function deselect(){ if(sel==null) return; sel=null; guide=null; syncPanel(); draw(); }
document.addEventListener("pointerdown",ev=>{ if(ev.target===cv) return; if(ev.target.closest&&ev.target.closest(".side")) return; deselect(); });
cv.addEventListener("pointermove",ev=>{ if(!drag)return; const r=cv.getBoundingClientRect(); let nx=Math.max(0.02,Math.min(0.98,(ev.clientX-r.left)/r.width)), ny=Math.max(0.02,Math.min(0.98,(ev.clientY-r.top)/r.height)); guide=null;
  if(document.getElementById("snap").checked && drag!="arc"){ const ox=[],oy=[]; for(const kk in P.el){ if(kk!=drag){ ox.push(P.el[kk].x); oy.push(P.el[kk].y);} } const sx=snapAxis(nx,ox), sy=snapAxis(ny,oy); nx=sx[0]; ny=sy[0]; guide={x:sx[1],y:sy[1]}; }
  if(drag=="arc"){ P.arc.rad=Math.max(120,Math.min(228, cy - ny*SZ)); guide=null; } else if(drag=="week"){ P.el.week.y=ny; } else { P.el[drag].x=nx; P.el[drag].y=ny; mirror(drag); } draw(); });
cv.addEventListener("pointerup",()=>{ drag=null; guide=null; cv.style.cursor="grab"; draw(); });

// Keyboard nudge: arrows move the selected element 1 px (Shift = 10 px), with the same mirroring
// as dragging. The battery arc moves radially (Up = toward the bezel), the week strip vertically
// only - both as when dragged. Ignored while typing in a field, so arrows still work there.
// Reading order of everything selectable - top to bottom, then left to right - from the CURRENT
// positions, so Tab order follows the layout even after things are moved. Rows are bucketed to
// ~3.5% of the screen so elements on the same line (e.g. Data 02 / 03) sort left to right.
function tabOrder(){ const items=[["arc",(cy-P.arc.rad)/SZ,0.5]].concat(Object.keys(P.el).map(k=>[k,P.el[k].y,P.el[k].x]));
  items.sort((a,b)=>(Math.round(a[1]/0.035)-Math.round(b[1]/0.035))||(a[2]-b[2])); return items.map(i=>i[0]); }
document.addEventListener("keydown",ev=>{
  const tag=(document.activeElement&&document.activeElement.tagName)||"";
  if(tag=="INPUT"||tag=="SELECT"||tag=="TEXTAREA"||tag=="BUTTON") return;
  // Tab / Shift+Tab: select the next / previous element (wraps round; starts at the first if
  // nothing is selected), ready to nudge with the arrows.
  if(ev.key=="Tab"){ ev.preventDefault(); const o=tabOrder(); const i=o.indexOf(sel);
    sel=(i<0)?o[ev.shiftKey?o.length-1:0]:o[(i+(ev.shiftKey?-1:1)+o.length)%o.length];
    syncPanel(); draw(); return; }
  if(ev.key=="Escape"){ deselect(); return; }
  if(!sel) return;
  const d={ArrowLeft:[-1,0],ArrowRight:[1,0],ArrowUp:[0,-1],ArrowDown:[0,1]}[ev.key];
  if(!d) return;
  ev.preventDefault();                       // don't scroll the page
  const step=ev.shiftKey?10:1;
  if(sel=="arc"){ if(d[1]) P.arc.rad=Math.max(120,Math.min(228,P.arc.rad-d[1]*step)); syncPanel(); draw(); return; }
  const e=P.el[sel]; if(!e) return;
  const clamp=v=>Math.max(0.02,Math.min(0.98,v));
  if(sel!="week") e.x=clamp(e.x+d[0]*step/SZ);
  e.y=clamp(e.y+d[1]*step/SZ);
  mirror(sel); draw();
});

const compSel=document.getElementById("compSel"); COMPS.forEach((c,i)=>{ const o=document.createElement("option"); o.value=i; o.textContent=c.k; compSel.appendChild(o); });
const fontSel=document.getElementById("fontSel");
FONT_GROUPS.forEach(([label,list])=>{
  const g=document.createElement("optgroup"); g.label=label;
  list.forEach(f=>{ const o=document.createElement("option"); o.value=f; o.textContent=f; g.appendChild(o); });
  fontSel.appendChild(g); });
function show(id,on){ document.getElementById(id).style.display=on?"flex":"none"; }
function cur(){ return sel=="arc"?P.arc:(sel?P.el[sel]:null); }
function syncPanel(){ const e=sel&&sel!="arc"?P.el[sel]:null; const isArc=sel=="arc";
  document.getElementById("selName").textContent=isArc?"Battery arc (top)":(e?e.name:"- none -");
  document.getElementById("ctlNone").style.display=(e||isArc)?"none":"block";
  const isData=e&&(e.kind=="chip"||e.kind=="ring"||e.kind=="tick"||e.kind=="horiz");
  const isRing=e&&(e.kind=="ring"||e.kind=="tick");
  show("ctlComp",isData); show("ctlRing",isRing); show("ctlGap",e&&e.kind=="time");
  show("ctlTick",e&&e.kind=="tick"); show("ctlKnock",e&&e.kind=="tick");
  show("ctlCity",!!(e&&isData&&COMPS[e.comp]&&COMPS[e.comp].tz));
  if(e&&e.kind=="tick"){ document.getElementById("tickSel").value=e.tick||"2px"; setR("knockR","knockRV",e.knock||0,0); }
  if(e&&COMPS[e.comp]&&COMPS[e.comp].tz){ document.getElementById("citySel").value=e.city||"New York"; }
  show("ctlText",e&&e.kind=="brand"); show("ctlFade",e&&e.kind=="time"); show("ctlDGap",e&&e.kind=="date"); show("ctlWeek",e&&e.kind=="week");
  show("ctlArcR",isArc); show("ctlArcSpan",isArc); show("ctlArcW",isArc); show("ctlArcL",isArc);
  show("ctlNum",!!e&&!isArc&&!(e&&e.kind=="ind")); show("ctlSym",isData||(e&&e.kind=="ind"));
  document.getElementById("numLbl").textContent=(e&&(e.kind=="time"||e.kind=="date"||e.kind=="week"))?"Text px":"Number px";
  if(isArc){ setR("aradR","aradRV",P.arc.rad,0); setR("aspanR","aspanRV",P.arc.span,0); setR("adwR","adwRV",P.arc.dashW,1); setR("adlR","adlRV",P.arc.dashLen,0); return; }
  if(!e)return; if(isData) compSel.value=e.comp;
  if(isRing) setR("ringR","ringRV",e.ring,0);
  var _nr=document.getElementById("numR"); if(e.kind=="time"){_nr.min=85;_nr.max=200;}else{_nr.min=8;_nr.max=120;} setR("numR","numRV",e.num||1,0); if(e.sym!=null) setR("symR","symRV",e.sym,0);
  if(e.kind=="time"){ setR("gapR","gapRV",e.gap,0); setR("fadeR","fadeRV",e.fade,2); }
  if(e.kind=="brand") document.getElementById("brandT").value=e.text;
  if(e.kind=="date") setR("dgapR","dgapRV",e.gap,0);
  if(e.kind=="week") setR("wspanR","wspanRV",e.span,0);
}
function setR(rid,vid,val,dp){ document.getElementById(rid).value=val; document.getElementById(vid).textContent=dp?(+val).toFixed(dp):(""+Math.round(val)); }
function linkVal(pid,hid,val){ document.getElementById(pid).value=val; document.getElementById(hid).value=val; }
compSel.onchange=()=>{ if(sel&&sel!="arc"){P.el[sel].comp=+compSel.value; syncPanel(); draw();} };
const citySel=document.getElementById("citySel"); CITIES.forEach(c=>{ const o=document.createElement("option"); o.value=c[0]; o.textContent=c[0]; citySel.appendChild(o); });
citySel.onchange=()=>{ if(sel&&sel!="arc"){ P.el[sel].city=citySel.value; draw(); } };
document.getElementById("tickSel").onchange=function(){ if(sel=="sec"){ P.el.sec.tick=this.value; draw(); } };
bindR("knockR","knockRV",0,v=>{ if(sel=="sec") P.el.sec.knock=v; });
document.getElementById("vfd").onchange=draw;
// Preview time & date sliders (see PV). Month changes clamp the day to that month's length.
function syncPV(){ document.getElementById("pvD").max=daysIn(); if(PV.day>daysIn()) PV.day=daysIn();
  setR("pvH","pvHV",PV.h,0); document.getElementById("pvHV").textContent=HH()+(PV.h24?"":(PV.h<12?"a":"p"));
  setR("pvM","pvMV",PV.m,0); document.getElementById("pvMV").textContent=MM();
  setR("pvS","pvSV",PV.s,0); document.getElementById("pvSV").textContent=pad2(PV.s);
  setR("pvD","pvDV",PV.day,0); setR("pvMo","pvMoV",PV.mon,0); document.getElementById("pvMoV").textContent=MON();
  document.getElementById("pv24").checked=PV.h24; }
[["pvH","h"],["pvM","m"],["pvS","s"],["pvD","day"],["pvMo","mon"]].forEach(([id,key])=>{
  document.getElementById(id).oninput=function(){ PV[key]=+this.value; syncPV(); draw(); }; });
document.getElementById("pv24").onchange=function(){ PV.h24=this.checked; syncPV(); draw(); };
document.getElementById("pvNow").onclick=function(){ pvNow(); syncPV(); draw(); };
syncPV();
function bindR(rid,vid,dp,fn){ document.getElementById(rid).oninput=function(){ fn(+this.value); if(sel&&sel!="arc") mirror(sel); document.getElementById(vid).textContent=dp?(+this.value).toFixed(dp):(""+Math.round(+this.value)); draw(); }; }
bindR("ringR","ringRV",0,v=>{if(sel&&sel!="arc")P.el[sel].ring=v;});
bindR("numR","numRV",0,v=>{if(sel&&sel!="arc")P.el[sel].num=v;});
bindR("symR","symRV",0,v=>{if(sel&&sel!="arc")P.el[sel].sym=v;});
bindR("gapR","gapRV",0,v=>{if(sel&&sel!="arc")P.el[sel].gap=v;});
bindR("fadeR","fadeRV",2,v=>{if(sel&&sel!="arc")P.el[sel].fade=v;});
bindR("dgapR","dgapRV",0,v=>{if(sel&&sel!="arc")P.el[sel].gap=v;});
bindR("wspanR","wspanRV",0,v=>{ if(Math.abs(v-P.arc.span)<4) v=P.arc.span; if(sel=="week"||sel&&P.el[sel]&&P.el[sel].kind=="week")P.el.week.span=v; document.getElementById("wspanR").value=v; });
bindR("aradR","aradRV",0,v=>{P.arc.rad=v;});
bindR("aspanR","aspanRV",0,v=>{P.arc.span=v;});
bindR("adwR","adwRV",1,v=>{P.arc.dashW=v;});
bindR("adlR","adlRV",0,v=>{P.arc.dashLen=v;});
// Colour themes: each sets all nine watch colours. Claude = the face's current palette; IV-22 =
// measured from Gumix's IV-22 digit art (core #a4f5e1, segment #1ec693); the VS Code themes use
// the exact accent/foreground hexes from porttracker's chart THEMES (webapp.py), mapped as:
// hour/values = foreground, icons+labels = comment grey (lifted to stay legible on black),
// gradient/rings/glows = a pair of the theme's accents, accent = its vivid highlight.
// The watch background stays black (AMOLED) in every theme.
const THEMES=[
 ["grid-teal","Claude Grid teal",{accent:"#a4f5e1",text1:"#1ec693",text2:"#7fe8c8",text3:"#13916b",hourCol:"#ffffff",grad1:"#b4eede",grad2:"#1ec693",hourGlow:"#1ec693",minGlow:"#1ec693"}],
 ["claude","Claude",{accent:"#ff531a",text1:"#ff9c75",text2:"#ffffff",text3:"#9a9a9a",hourCol:"#FFFFFF",grad1:"#ff9255",grad2:"#ff3c3b",hourGlow:"#ffc4a4",minGlow:"#ff6e46"}],
 ["iv22","IV-22 (VFD teal)",{accent:"#a4f5e1",text1:"#1ec693",text2:"#7fe8c8",text3:"#13916b",hourCol:"#a4f5e1",grad1:"#5fe3bd",grad2:"#1ec693",hourGlow:"#1ec693",minGlow:"#1ec693"}],
 ["github-dark","GitHub Dark",{accent:"#f78166",text1:"#79c0ff",text2:"#e6edf3",text3:"#8b949e",hourCol:"#e6edf3",grad1:"#58a6ff",grad2:"#bc8cff",hourGlow:"#a5d6ff",minGlow:"#58a6ff"}],
 ["one-dark","One Dark",{accent:"#e06c75",text1:"#e5c07b",text2:"#abb2bf",text3:"#7f848e",hourCol:"#dcdfe4",grad1:"#61afef",grad2:"#c678dd",hourGlow:"#61afef",minGlow:"#61afef"}],
 ["dracula","Dracula",{accent:"#ff79c6",text1:"#8be9fd",text2:"#f8f8f2",text3:"#6272a4",hourCol:"#f8f8f2",grad1:"#bd93f9",grad2:"#ff79c6",hourGlow:"#bd93f9",minGlow:"#ff79c6"}],
 ["monokai","Monokai",{accent:"#f92672",text1:"#e6db74",text2:"#f8f8f2",text3:"#88846f",hourCol:"#f8f8f2",grad1:"#fd971f",grad2:"#f92672",hourGlow:"#e6db74",minGlow:"#fd971f"}],
 ["nord","Nord",{accent:"#d08770",text1:"#88c0d0",text2:"#eceff4",text3:"#7b88a1",hourCol:"#eceff4",grad1:"#8fbcbb",grad2:"#5e81ac",hourGlow:"#88c0d0",minGlow:"#81a1c1"}],
 ["tokyo-night","Tokyo Night",{accent:"#ff9e64",text1:"#7aa2f7",text2:"#c0caf5",text3:"#737aa2",hourCol:"#c0caf5",grad1:"#7dcfff",grad2:"#bb9af7",hourGlow:"#7aa2f7",minGlow:"#bb9af7"}],
 ["solarized","Solarized",{accent:"#cb4b16",text1:"#b58900",text2:"#eee8d5",text3:"#839496",hourCol:"#fdf6e3",grad1:"#2aa198",grad2:"#268bd2",hourGlow:"#93a1a1",minGlow:"#2aa198"}],
 ["synthwave","Synthwave (current face)",{accent:"#fede5d",text1:"#36f9f6",text2:"#ffffff",text3:"#848bbd",hourCol:"#ffffff",grad1:"#ff7edb",grad2:"#f97e72",hourGlow:"#ff7edb",minGlow:"#fc28a8"}],
 ["night-owl","Night Owl",{accent:"#f78c6c",text1:"#82aaff",text2:"#d6deeb",text3:"#7f9c9c",hourCol:"#d6deeb",grad1:"#7fdbca",grad2:"#c792ea",hourGlow:"#82aaff",minGlow:"#7fdbca"}],
];
const themeSel=document.getElementById("themeSel");
THEMES.concat([["custom","Custom",null]]).forEach(([k,l])=>{ const o=document.createElement("option"); o.value=k; o.textContent=l; themeSel.appendChild(o); });
function applyTheme(k){ const th=THEMES.find(t=>t[0]==k); if(!th) return; Object.assign(P,th[2]); P.theme=k; themeSel.value=k; linkAllColours(); draw(); }
themeSel.onchange=function(){ if(this.value!="custom") applyTheme(this.value); else { P.theme="custom"; draw(); } };
function markCustom(){ P.theme="custom"; themeSel.value="custom"; }
function bindColor(pid,hid,set){ const p=document.getElementById(pid), h=document.getElementById(hid);
  p.oninput=()=>{ h.value=p.value; set(p.value); markCustom(); draw(); };
  h.oninput=()=>{ let v=h.value.trim(); if(!/^#/.test(v)) v="#"+v; if(/^#[0-9a-fA-F]{6}$/.test(v)){ p.value=v; set(v); markCustom(); draw(); } }; }
bindColor("cAcc","cAccH",v=>P.accent=v); bindColor("cT1","cT1H",v=>P.text1=v); bindColor("cT2","cT2H",v=>P.text2=v);
bindColor("cT3","cT3H",v=>P.text3=v); bindColor("cHc","cHcH",v=>P.hourCol=v);
bindColor("cG1","cG1H",v=>P.grad1=v); bindColor("cG2","cG2H",v=>P.grad2=v);
// A glow colour only shows in VFD style, so editing one switches the VFD preview on rather
// than appearing to do nothing.
function glowEdit(set){ return v=>{ set(v); document.getElementById("vfd").checked=true; }; }
bindColor("cHg","cHgH",glowEdit(v=>P.hourGlow=v)); bindColor("cMg","cMgH",glowEdit(v=>P.minGlow=v));
document.getElementById("brandT").oninput=function(){ if(sel=="brand"){ P.el.brand.text=this.value; draw(); } };
fontSel.onchange=function(){ setFont(this.value); };
document.getElementById("lowp").onchange=draw;
// Fonts load from Google Fonts on demand. To avoid a flash of a fallback face, the watch keeps
// drawing in the CURRENT font until the new one is actually loaded, then switches once
// (fontLoaded). Rapid scrolling through the menu only applies the latest pick (fontReq), and all
// fonts are prefetched in the background after start-up so scrolling is usually instant.
const _fontCss={};   // family -> Promise resolved when its Google Fonts stylesheet has loaded
function fontCss(name){
  if(!_fontCss[name]){ _fontCss[name]=new Promise(res=>{ const id="gf-"+name.replace(/ /g,'-');
    let l=document.getElementById(id);
    if(!l){ l=document.createElement("link"); l.id=id; l.rel="stylesheet"; l.href="https://fonts.googleapis.com/css2?family="+name.replace(/ /g,"+")+"&display=swap"; document.head.appendChild(l); }
    else if(l.sheet){ res(); return; }
    l.addEventListener("load",()=>res()); l.addEventListener("error",()=>res()); setTimeout(res,4000); }); }
  return _fontCss[name]; }
function fontLoaded(name){ return fontCss(name).then(()=> document.fonts&&document.fonts.load ? document.fonts.load("40px '"+name+"'").catch(()=>{}) : null); }
let fontReq=0;
function setFont(name){ const my=++fontReq;
  const apply=()=>{ if(my!==fontReq) return; P.font=name; draw(); };
  const giveUp=setTimeout(apply,5000);               // never get stuck on a font that won't load
  fontLoaded(name).then(()=>{ clearTimeout(giveUp); apply(); }); }
function prefetchFonts(){ const all=[].concat(...FONT_GROUPS.map(g=>g[1])); let i=0;
  const next=()=>{ if(i>=all.length) return; const f=all[i++]; fontLoaded(f).then(()=>setTimeout(next,40)); };
  next(); next(); }                                   // two at a time
function refresh(){ let L=["font: "+P.font,"theme: "+P.theme,"style: "+(P.vfd?"VFD (glow time + full-face mesh)":"plain"),"glow: hour="+P.hourGlow+"  minute="+P.minGlow,"accent: "+P.accent,"text1: "+P.text1+"  text2: "+P.text2+"  text3: "+P.text3,"hour: "+P.hourCol+"  grad1: "+P.grad1+"  grad2: "+P.grad2,
  "arc: rad="+Math.round(P.arc.rad)+" span="+P.arc.span+" dashW="+P.arc.dashW+" dashLen="+P.arc.dashLen,""];
  for(const k in P.el){ const e=P.el[k]; let s=k.padEnd(6)+" ("+e.name+")  x="+e.x.toFixed(3)+" y="+e.y.toFixed(3);
    if(e.comp!=null) s+="  comp="+COMPS[e.comp].k; if(e.ring!=null) s+="  ring="+Math.round(e.ring)+"px";
    if(e.num!=null) s+="  num="+Math.round(e.num)+"px"; if(e.sym!=null) s+="  sym="+Math.round(e.sym)+"px";
    if(e.gap!=null) s+="  gap="+Math.round(e.gap)+"px";
    if(e.span!=null) s+="  width="+e.span; if(e.fade!=null) s+="  fade="+(+e.fade).toFixed(2); if(e.text!=null) s+="  text=\""+e.text+"\"";
    if(e.tick!=null) s+="  ticks="+e.tick; if(e.knock!=null) s+="  knockout="+e.knock+"px";
    if(e.city!=null && e.comp!=null && COMPS[e.comp].tz) s+="  city="+e.city; L.push(s); }
  out.value=L.join("\n"); }
function linkAllColours(){ linkVal("cHg","cHgH",P.hourGlow); linkVal("cMg","cMgH",P.minGlow); linkVal("cAcc","cAccH",P.accent); linkVal("cT1","cT1H",P.text1); linkVal("cT2","cT2H",P.text2); linkVal("cT3","cT3H",P.text3); linkVal("cHc","cHcH",P.hourCol); linkVal("cG1","cG1H",P.grad1); linkVal("cG2","cG2H",P.grad2); }
function copyOut(){ out.select(); document.execCommand("copy"); }
function reset(){ P=defaults(); sel=null; guide=null; themeSel.value=P.theme; document.getElementById("vfd").checked=P.vfd; document.getElementById("fontSel").value=P.font; linkAllColours(); syncPanel(); setFont(P.font); }
linkAllColours();
// Start in the face's own style. Only reset() used to copy P.vfd into the checkbox, so the page
// opened with VFD unticked - draw() reads the checkbox, turned P.vfd off, and the Hour / Minute
// glow pickers silently did nothing (the glow is only drawn in VFD style).
document.getElementById("vfd").checked=P.vfd; themeSel.value=P.theme;   // the theme had the same load-time gap
document.getElementById("fontSel").value=P.font; syncPanel(); setFont(P.font); setTimeout(prefetchFonts,1500);
</script></body></html>"""
HTML = HTML.replace("__ICONS__", icons_js).replace("__FONT_GROUPS__", font_groups_js)
open(OUT, "w", encoding="utf-8").write(HTML)
print("wrote", OUT, os.path.getsize(OUT), "bytes")
