// WWAV — earthy / gradual / Turrell-inspired

// Earthy palette — soft sand, dusty taupe, warm clay
const SAND      = '#E8DCC8';       // page background — warm sand
const SAND_DEEP = '#D4C4A8';       // shadow tone
const CLAY      = '#B89878';       // mid taupe
const CLAY_DEEP = '#7A5E45';       // dark earth
const INK       = '#3D2E22';       // soft brown-black (never pure black)
const MUTED     = '#8A7560';       // dusty mid
const GLOW      = '#FFE9C8';       // warm light
const ACCENT    = '#C89668';       // amber clay

// Gradual / atmospheric type
const SERIF = '"Fraunces", "Cormorant Garamond", "Times New Roman", serif';
const SANS  = '"Fraunces", -apple-system, system-ui, sans-serif'; // we use one family, varied via opsz/wght
const MONO  = '"Fraunces", ui-monospace, monospace'; // even labels — gradual feel

// fraunces variation styles
const fraunces = (size, weight = 300, opsz = 144, soft = 100) =>
  ({ fontFamily: SERIF, fontSize: size, fontWeight: weight, fontVariationSettings: `"opsz" ${opsz}, "SOFT" ${soft}, "WONK" 0`, letterSpacing: -0.01 * size });

// ────────────────────────────────────────────────────────────
// Stem Player — Turrell-style luminous taupe sphere
// ────────────────────────────────────────────────────────────
function StemPlayer({ size = 320 }) {
  const r = size / 2;

  // 4 LEDs per cardinal arm (matching reference)
  const arms = [
    { angle:   0, label: 'VOX'   }, // top
    { angle:  90, label: 'BASS'  }, // right
    { angle: 180, label: 'DRUM'  }, // bottom
    { angle: 270, label: 'SYNTH' }, // left
  ];

  const LEDS_PER_ARM = 4;
  const dotSize = size * 0.022;

  return (
    <div style={{ width: size, height: size, position: 'relative' }}>
      {/* Outer ambient glow — Turrell light wash */}
      <div style={{
        position: 'absolute', inset: -size * 0.15, borderRadius: '50%',
        background: `radial-gradient(circle at 50% 55%, rgba(255,220,170,0.25) 0%, rgba(255,220,170,0.08) 35%, transparent 65%)`,
        filter: 'blur(20px)',
      }}/>

      {/* The sphere — soft matte taupe with gradual top-down light */}
      <div style={{
        position: 'absolute', inset: 0, borderRadius: '50%',
        background: `
          radial-gradient(circle at 38% 28%, #E0CCB0 0%, #C8AC8A 28%, #A88864 60%, #8A6A48 88%, #6A4E32 100%)
        `,
        boxShadow: `
          inset -8px -16px 40px rgba(60,40,25,0.45),
          inset 4px 6px 20px rgba(255,230,190,0.35),
          0 30px 60px rgba(80,55,30,0.35),
          0 8px 16px rgba(80,55,30,0.25)
        `,
      }}/>

      {/* Soft top-light highlight (Turrell sky glow) */}
      <div style={{
        position: 'absolute', top: '8%', left: '22%',
        width: '56%', height: '40%', borderRadius: '50%',
        background: 'radial-gradient(ellipse at 50% 30%, rgba(255,240,210,0.55) 0%, rgba(255,240,210,0.15) 50%, transparent 75%)',
        filter: 'blur(8px)',
        pointerEvents: 'none',
      }}/>

      {/* Bottom soft shadow contour */}
      <div style={{
        position: 'absolute', bottom: '4%', left: '15%',
        width: '70%', height: '20%', borderRadius: '50%',
        background: 'radial-gradient(ellipse at 50% 50%, rgba(50,30,15,0.25) 0%, transparent 70%)',
        filter: 'blur(6px)',
        pointerEvents: 'none',
      }}/>

      {/* LED dots along cardinals */}
      {arms.map((arm, ai) => {
        const dots = [];
        for (let i = 0; i < LEDS_PER_ARM; i++) {
          // distance from center: skip the very center, go from 0.18r to 0.78r
          const t = 0.22 + (i / (LEDS_PER_ARM - 1)) * 0.55;
          const rad = (arm.angle - 90) * Math.PI / 180;
          const x = r + Math.cos(rad) * r * t;
          const y = r + Math.sin(rad) * r * t;
          // glow strongest at outer dots
          const glowStrength = 0.55 + (i / LEDS_PER_ARM) * 0.4;
          dots.push(
            <div key={`${ai}-${i}`} style={{
              position: 'absolute',
              left: x - dotSize/2, top: y - dotSize/2,
              width: dotSize, height: dotSize, borderRadius: '50%',
              background: `radial-gradient(circle at 50% 40%, #FFF6E0 0%, #FFE2B0 50%, ${ACCENT} 100%)`,
              boxShadow: `
                0 0 ${dotSize * 1.5}px rgba(255,220,170,${glowStrength}),
                0 0 ${dotSize * 0.6}px rgba(255,200,150,${glowStrength * 0.8}),
                inset 0 0 ${dotSize * 0.3}px rgba(255,255,230,0.6)
              `,
            }}/>
          );
        }
        return dots;
      })}

      {/* Center — subtle indented play disc */}
      <div style={{
        position: 'absolute', left: r - size*0.06, top: r - size*0.06,
        width: size*0.12, height: size*0.12, borderRadius: '50%',
        background: 'radial-gradient(circle at 40% 35%, #A88864 0%, #7A5A3E 70%, #5A4028 100%)',
        boxShadow: 'inset 0 2px 4px rgba(40,25,15,0.6), inset 0 -1px 2px rgba(255,220,180,0.2)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        {/* very faint play+plus glyph */}
        <svg width={size*0.05} height={size*0.05} viewBox="0 0 20 20" style={{ opacity: 0.5 }}>
          <polygon points="6,5 6,15 15,10" fill="#FFE9C8"/>
        </svg>
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// Tab bar — soft, no harsh black
// ────────────────────────────────────────────────────────────
const TabIcon = ({ name, active }) => {
  const c = active ? INK : MUTED;
  const s = 22;
  switch (name) {
    case 'home': return (
      <svg width={s} height={s} viewBox="0 0 24 24" fill="none">
        <path d="M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-7h-6v7H4a1 1 0 0 1-1-1z" stroke={c} strokeWidth="1.4" strokeLinejoin="round"/>
      </svg>
    );
    case 'search': return (
      <svg width={s} height={s} viewBox="0 0 24 24" fill="none">
        <circle cx="10.5" cy="10.5" r="6.5" stroke={c} strokeWidth="1.4"/>
        <path d="M15.5 15.5l4 4" stroke={c} strokeWidth="1.4" strokeLinecap="round"/>
      </svg>
    );
    case 'play': return (
      <svg width={s} height={s} viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="9" stroke={c} strokeWidth="1.4"/>
        <polygon points="10,8 10,16 16,12" fill={c}/>
      </svg>
    );
    case 'plus': return (
      <svg width={s} height={s} viewBox="0 0 24 24" fill="none">
        <line x1="12" y1="5" x2="12" y2="19" stroke={c} strokeWidth="1.5" strokeLinecap="round"/>
        <line x1="5" y1="12" x2="19" y2="12" stroke={c} strokeWidth="1.5" strokeLinecap="round"/>
      </svg>
    );
    case 'profile': return (
      <svg width={s} height={s} viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="9" r="3.5" stroke={c} strokeWidth="1.4"/>
        <path d="M5 20c1.5-4 4-6 7-6s5.5 2 7 6" stroke={c} strokeWidth="1.4" strokeLinecap="round"/>
      </svg>
    );
  }
};

function TabBar({ active, onChange }) {
  const tabs = ['home', 'search', 'play', 'plus', 'profile'];
  return (
    <div style={{
      position: 'absolute', bottom: 0, left: 0, right: 0,
      paddingBottom: 28, paddingTop: 12,
      background: `linear-gradient(180deg, ${SAND} 0%, ${SAND_DEEP} 100%)`,
      display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)',
      zIndex: 30,
    }}>
      {tabs.map(t => (
        <button key={t} onClick={() => onChange(t)} style={{
          background: 'none', border: 'none', padding: '10px 0',
          display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4,
          cursor: 'pointer',
        }}>
          <div style={{
            width: 44, height: 30, borderRadius: 99,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            background: active === t
              ? `radial-gradient(ellipse at center, ${GLOW} 0%, ${ACCENT}50 70%, transparent 100%)`
              : 'transparent',
          }}>
            <TabIcon name={t} active={active === t}/>
          </div>
        </button>
      ))}
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// Status bar
// ────────────────────────────────────────────────────────────
function StatusBar() {
  return (
    <div style={{
      height: 54, padding: '20px 28px 0',
      display: 'flex', justifyContent: 'space-between', alignItems: 'center',
      ...fraunces(15, 400),
      color: INK,
    }}>
      <div>9:41</div>
      <div style={{ display: 'flex', gap: 6, alignItems: 'center', opacity: 0.7 }}>
        <svg width="16" height="10" viewBox="0 0 16 10"><rect x="0" y="6" width="2.5" height="4" rx="0.5" fill={INK}/><rect x="4" y="4" width="2.5" height="6" rx="0.5" fill={INK}/><rect x="8" y="2" width="2.5" height="8" rx="0.5" fill={INK}/><rect x="12" y="0" width="2.5" height="10" rx="0.5" fill={INK}/></svg>
        <svg width="22" height="10" viewBox="0 0 22 10"><rect x="0.5" y="0.5" width="19" height="9" rx="2.5" stroke={INK} strokeOpacity="0.4" fill="none"/><rect x="2" y="2" width="14" height="6" rx="1" fill={INK}/></svg>
      </div>
    </div>
  );
}

// Soft horizontal rule (Turrell style — gradual fade)
function SoftRule() {
  return (
    <div style={{
      height: 1,
      background: `linear-gradient(90deg, transparent 0%, ${MUTED}40 20%, ${MUTED}40 80%, transparent 100%)`,
    }}/>
  );
}

// ────────────────────────────────────────────────────────────
// PLAY screen
// ────────────────────────────────────────────────────────────
function PlayScreen() {
  return (
    <div style={{
      flex: 1, display: 'flex', flexDirection: 'column',
      padding: '8px 28px 110px',
      background: `radial-gradient(ellipse at 50% 45%, ${SAND} 0%, ${SAND_DEEP} 100%)`,
      position: 'relative',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginTop: 6 }}>
        <div style={{ ...fraunces(11, 300), color: MUTED, letterSpacing: 2.5, textTransform: 'uppercase' }}>now playing</div>
        <div style={{ ...fraunces(11, 300), color: MUTED, letterSpacing: 2 }}>02 / 14</div>
      </div>

      <div style={{ marginTop: 14 }}>
        <div style={{ ...fraunces(46, 300, 144, 100), color: INK, lineHeight: 1, fontStyle: 'italic' }}>
          Lowtide
        </div>
        <div style={{ ...fraunces(13, 300), color: MUTED, marginTop: 8, letterSpacing: 1.5, textTransform: 'uppercase' }}>
          moss hall — unreleased
        </div>
      </div>

      <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '8px 0' }}>
        <StemPlayer size={300} />
      </div>

      {/* timeline */}
      <div style={{ marginBottom: 18 }}>
        <div style={{ height: 1.5, background: `${MUTED}30`, position: 'relative', borderRadius: 1 }}>
          <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: '38%', background: `linear-gradient(90deg, ${MUTED}80, ${INK})`, borderRadius: 1 }}/>
          <div style={{ position: 'absolute', left: 'calc(38% - 4px)', top: -4, width: 9, height: 9, borderRadius: 5, background: GLOW, boxShadow: `0 0 8px ${ACCENT}, 0 0 2px ${INK}` }}/>
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 10, ...fraunces(11, 300), color: MUTED, letterSpacing: 1.5 }}>
          <span>1:24</span><span>3:42</span>
        </div>
      </div>

      {/* stems */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        {[['vox', 0.8], ['bass', 0.6], ['drum', 0.9], ['synth', 0.4]].map(([name, val]) => (
          <div key={name} style={{
            background: `linear-gradient(180deg, ${SAND} 0%, ${SAND_DEEP}80 100%)`,
            border: `1px solid ${MUTED}25`, borderRadius: 99,
            padding: '8px 14px',
            display: 'flex', alignItems: 'center', gap: 10,
            boxShadow: `inset 0 1px 1px ${GLOW}40, 0 1px 2px rgba(60,40,25,0.08)`,
          }}>
            <span style={{ ...fraunces(11, 400), color: INK, width: 38, textTransform: 'lowercase', fontStyle: 'italic' }}>{name}</span>
            <div style={{ flex: 1, height: 2, background: `${MUTED}25`, position: 'relative', borderRadius: 1 }}>
              <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: `${val*100}%`, background: `linear-gradient(90deg, ${ACCENT}, ${CLAY_DEEP})`, borderRadius: 1 }}/>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// HOME — feed
// ────────────────────────────────────────────────────────────
function MiniWaveform({ accent = false }) {
  const bars = [3,7,12,8,16,22,18,11,6,9,14,20,16,10,5,8,13,18,14,7];
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 1.5, height: 22 }}>
      {bars.map((h, i) => (
        <div key={i} style={{
          width: 2, height: h, borderRadius: 1,
          background: accent
            ? (i < 8 ? ACCENT : `${ACCENT}40`)
            : (i < 8 ? INK : `${INK}30`),
        }}/>
      ))}
    </div>
  );
}

function FeedItem({ name, handle, song, time, plays, accent }) {
  return (
    <div style={{ padding: '20px 24px', display: 'flex', gap: 14, position: 'relative' }}>
      <div style={{
        width: 44, height: 44, borderRadius: '50%', flexShrink: 0,
        background: `radial-gradient(circle at 35% 30%, ${SAND} 0%, ${CLAY} 60%, ${CLAY_DEEP} 100%)`,
        boxShadow: `inset -2px -3px 4px rgba(60,40,25,0.3), inset 1px 1px 2px ${GLOW}80, 0 2px 4px rgba(60,40,25,0.15)`,
      }}/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
          <span style={{ ...fraunces(15, 500), color: INK }}>{name}</span>
          <span style={{ ...fraunces(12, 300), color: MUTED }}>@{handle}</span>
          <span style={{ ...fraunces(12, 300), color: MUTED, marginLeft: 'auto' }}>{time}</span>
        </div>
        <div style={{
          marginTop: 12,
          background: `linear-gradient(135deg, ${SAND} 0%, ${SAND_DEEP}60 100%)`,
          border: `1px solid ${MUTED}20`,
          borderRadius: 14,
          padding: '14px 16px',
          display: 'flex', alignItems: 'center', gap: 12,
          boxShadow: `inset 0 1px 1px ${GLOW}50, 0 2px 6px rgba(60,40,25,0.06)`,
        }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ ...fraunces(20, 300, 144, 100), color: INK, lineHeight: 1.05, fontStyle: 'italic' }}>{song}</div>
            <div style={{ marginTop: 8 }}><MiniWaveform accent={accent}/></div>
          </div>
          <button style={{
            width: 40, height: 40, borderRadius: '50%',
            background: `radial-gradient(circle at 35% 30%, ${CLAY} 0%, ${CLAY_DEEP} 80%)`,
            border: 'none', flexShrink: 0,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            cursor: 'pointer',
            boxShadow: `inset -1px -2px 3px rgba(40,25,15,0.4), inset 1px 1px 2px ${GLOW}50, 0 2px 4px rgba(60,40,25,0.2)`,
          }}>
            <svg width="11" height="11" viewBox="0 0 12 12">
              <polygon points="3,1 3,11 11,6" fill={GLOW}/>
            </svg>
          </button>
        </div>
        <div style={{ display: 'flex', gap: 22, marginTop: 12, ...fraunces(11, 300), color: MUTED, letterSpacing: 1 }}>
          <span>{plays} plays</span>
          <span>↻ 12</span>
          <span>♡ 84</span>
          <span style={{ marginLeft: 'auto' }}>+ add</span>
        </div>
      </div>
    </div>
  );
}

function HomeScreen() {
  return (
    <div style={{
      flex: 1, display: 'flex', flexDirection: 'column', paddingBottom: 84,
      background: `radial-gradient(ellipse at 50% 0%, ${SAND} 0%, ${SAND_DEEP} 100%)`,
    }}>
      <div style={{ padding: '14px 24px 18px' }}>
        <div style={{ ...fraunces(48, 300, 144, 100), color: INK, lineHeight: 1, fontStyle: 'italic', letterSpacing: -1 }}>
          wwav
        </div>
      </div>
      <div style={{
        display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)',
        padding: '0 24px',
        gap: 4,
      }}>
        {[['for you', true], ['following', false], ['friends', false]].map(([label, on]) => (
          <div key={label} style={{
            padding: '10px 0', textAlign: 'center',
            ...fraunces(13, on ? 500 : 300),
            color: on ? INK : MUTED,
            fontStyle: 'italic',
            borderBottom: on ? `1.5px solid ${ACCENT}` : `1px solid ${MUTED}20`,
          }}>{label}</div>
        ))}
      </div>
      <div style={{ flex: 1, overflowY: 'auto', marginTop: 4 }}>
        <FeedItem name="Moss Hall" handle="moss" song="Lowtide" time="2h" plays="1.2K" accent={true}/>
        <SoftRule/>
        <FeedItem name="June Carver" handle="junec" song="Velvet Static" time="5h" plays="408" />
        <SoftRule/>
        <FeedItem name="Neon Pastor" handle="neonp" song="Sunday, again" time="1d" plays="2.4K" />
        <SoftRule/>
        <FeedItem name="Kit Wren" handle="kitwren" song="Halflight" time="2d" plays="611" />
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// UPLOAD
// ────────────────────────────────────────────────────────────
function UploadEmpty({ onPlus }) {
  return (
    <div style={{
      flex: 1, padding: '60px 28px 110px',
      background: `radial-gradient(ellipse at 50% 45%, ${SAND} 0%, ${SAND_DEEP} 100%)`,
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 36,
    }}>
      <div style={{ ...fraunces(11, 300), color: MUTED, letterSpacing: 2.5, textTransform: 'uppercase' }}>upload a wav</div>
      <button onClick={onPlus} style={{
        width: 220, height: 220, borderRadius: '50%',
        border: 'none', cursor: 'pointer',
        background: `radial-gradient(circle at 38% 28%, ${SAND} 0%, ${CLAY} 60%, ${CLAY_DEEP} 100%)`,
        boxShadow: `
          inset -8px -16px 36px rgba(60,40,25,0.4),
          inset 4px 6px 18px ${GLOW}70,
          0 24px 48px rgba(80,55,30,0.3),
          0 8px 16px rgba(80,55,30,0.2)
        `,
        position: 'relative',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        {/* Turrell light wash on top */}
        <div style={{
          position: 'absolute', top: '8%', left: '20%',
          width: '60%', height: '40%', borderRadius: '50%',
          background: 'radial-gradient(ellipse at 50% 30%, rgba(255,240,210,0.5) 0%, transparent 75%)',
          filter: 'blur(8px)', pointerEvents: 'none',
        }}/>
        {/* glowing plus */}
        <svg width="80" height="80" viewBox="0 0 80 80" style={{ position: 'relative', zIndex: 2, filter: `drop-shadow(0 0 12px ${GLOW})` }}>
          <line x1="40" y1="18" x2="40" y2="62" stroke={GLOW} strokeWidth="3" strokeLinecap="round"/>
          <line x1="18" y1="40" x2="62" y2="40" stroke={GLOW} strokeWidth="3" strokeLinecap="round"/>
        </svg>
      </button>
      <div style={{ ...fraunces(26, 300, 144, 100), color: INK, textAlign: 'center', maxWidth: 260, lineHeight: 1.2, fontStyle: 'italic' }}>
        drop a track. start a wave.
      </div>
      <div style={{ ...fraunces(11, 300), color: MUTED, letterSpacing: 1.5, textAlign: 'center' }}>
        wav · mp3 · flac · up to 50mb
      </div>
    </div>
  );
}

function UploadFilled({ onBack }) {
  return (
    <div style={{
      flex: 1, padding: '20px 28px 110px',
      background: `radial-gradient(ellipse at 50% 0%, ${SAND} 0%, ${SAND_DEEP} 100%)`,
      display: 'flex', flexDirection: 'column', gap: 18,
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 4 }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', ...fraunces(12, 300), color: MUTED, letterSpacing: 1.5, cursor: 'pointer', padding: 0, fontStyle: 'italic' }}>← cancel</button>
        <div style={{ ...fraunces(11, 300), color: MUTED, letterSpacing: 2.5, textTransform: 'uppercase' }}>new upload</div>
      </div>

      <div style={{ ...fraunces(40, 300, 144, 100), color: INK, lineHeight: 1, marginTop: 8, fontStyle: 'italic' }}>
        new track
      </div>

      <div>
        <label style={{ ...fraunces(10, 300), color: MUTED, letterSpacing: 2, textTransform: 'uppercase' }}>song title</label>
        <div style={{
          marginTop: 6,
          borderBottom: `1px solid ${MUTED}40`,
          padding: '8px 0',
          ...fraunces(24, 300, 144, 100), color: INK, fontStyle: 'italic',
        }}>
          Lowtide
        </div>
      </div>

      <div>
        <label style={{ ...fraunces(10, 300), color: MUTED, letterSpacing: 2, textTransform: 'uppercase' }}>bio / notes</label>
        <div style={{
          marginTop: 8,
          background: `linear-gradient(135deg, ${SAND} 0%, ${SAND_DEEP}60 100%)`,
          border: `1px solid ${MUTED}25`,
          borderRadius: 14,
          padding: '14px 16px', minHeight: 84,
          ...fraunces(15, 300), color: INK, lineHeight: 1.5,
          boxShadow: `inset 0 1px 1px ${GLOW}50`,
        }}>
          recorded in a kitchen at 4am.<br/>
          four stems, mixed loose. no master.
          <span style={{ display: 'inline-block', width: 1.5, height: 18, background: INK, marginLeft: 1, verticalAlign: 'middle', animation: 'blink 1s infinite' }}/>
        </div>
      </div>

      <div>
        <label style={{ ...fraunces(10, 300), color: MUTED, letterSpacing: 2, textTransform: 'uppercase' }}>song file</label>
        <div style={{
          marginTop: 8,
          background: `linear-gradient(135deg, ${CLAY}30 0%, ${CLAY_DEEP}20 100%)`,
          border: `1px solid ${MUTED}40`,
          borderRadius: 14,
          padding: '14px 16px', display: 'flex', alignItems: 'center', gap: 14,
          boxShadow: `inset 0 1px 1px ${GLOW}50`,
        }}>
          <div style={{
            width: 36, height: 36, borderRadius: '50%',
            background: `radial-gradient(circle at 35% 30%, ${CLAY} 0%, ${CLAY_DEEP} 80%)`,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: `inset -1px -2px 3px rgba(40,25,15,0.4), inset 1px 1px 2px ${GLOW}50`,
          }}>
            <span style={{ ...fraunces(9, 500), color: GLOW, letterSpacing: 1 }}>WAV</span>
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ ...fraunces(14, 400), color: INK }}>lowtide_v3_master.wav</div>
            <div style={{ ...fraunces(11, 300), color: MUTED, marginTop: 2 }}>3:42 · 38.4 mb · 44.1khz</div>
          </div>
          <span style={{ ...fraunces(13, 300), color: MUTED }}>✕</span>
        </div>
        <div style={{ marginTop: 12, height: 44, display: 'flex', alignItems: 'center', gap: 1.5, padding: '0 2px' }}>
          {Array.from({ length: 80 }).map((_, i) => {
            const h = 6 + Math.abs(Math.sin(i * 0.4) * Math.cos(i * 0.13)) * 36;
            return <div key={i} style={{ flex: 1, height: h, background: i < 30 ? ACCENT : MUTED, opacity: i < 30 ? 0.9 : 0.35, borderRadius: 1 }}/>;
          })}
        </div>
      </div>

      <button style={{
        marginTop: 'auto',
        background: `linear-gradient(180deg, ${CLAY} 0%, ${CLAY_DEEP} 100%)`,
        color: GLOW, border: 'none',
        padding: '18px 0', borderRadius: 99,
        ...fraunces(15, 400), letterSpacing: 2, textTransform: 'lowercase', fontStyle: 'italic',
        cursor: 'pointer',
        boxShadow: `inset 0 1px 1px ${GLOW}40, inset 0 -1px 2px rgba(40,25,15,0.3), 0 4px 12px rgba(60,40,25,0.2)`,
        display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10,
      }}>
        upload track
      </button>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// SEARCH
// ────────────────────────────────────────────────────────────
function SearchScreen() {
  const tags = ['ambient', 'demo', 'kitchen pop', 'noise', 'late night', '4am', 'lo-fi', 'stems'];
  const results = [
    { title: 'Lowtide', artist: 'Moss Hall', plays: '1.2K' },
    { title: 'Velvet Static', artist: 'June Carver', plays: '408' },
    { title: 'Sunday, again', artist: 'Neon Pastor', plays: '2.4K' },
    { title: 'Halflight', artist: 'Kit Wren', plays: '611' },
    { title: 'Iron tooth', artist: 'Sable Lou', plays: '189' },
    { title: 'Pollen ghost', artist: 'Ada Vexx', plays: '3.1K' },
  ];
  return (
    <div style={{
      flex: 1, padding: '8px 0 110px',
      background: `radial-gradient(ellipse at 50% 0%, ${SAND} 0%, ${SAND_DEEP} 100%)`,
    }}>
      <div style={{ padding: '16px 24px 0' }}>
        <div style={{ ...fraunces(40, 300, 144, 100), color: INK, lineHeight: 1, fontStyle: 'italic' }}>
          search
        </div>
      </div>
      <div style={{ padding: '16px 24px 0' }}>
        <div style={{
          background: `linear-gradient(135deg, ${SAND} 0%, ${SAND_DEEP}60 100%)`,
          border: `1px solid ${MUTED}25`,
          borderRadius: 99,
          padding: '12px 18px', display: 'flex', alignItems: 'center', gap: 10,
          boxShadow: `inset 0 1px 1px ${GLOW}50`,
        }}>
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
            <circle cx="6" cy="6" r="4.5" stroke={INK} strokeWidth="1.4"/>
            <path d="M9.5 9.5l3 3" stroke={INK} strokeWidth="1.4" strokeLinecap="round"/>
          </svg>
          <span style={{ ...fraunces(16, 300), color: INK, fontStyle: 'italic' }}>moss</span>
          <span style={{ width: 1.5, height: 16, background: INK, animation: 'blink 1s infinite' }}/>
        </div>
      </div>
      <div style={{ padding: '16px 24px 0', display: 'flex', flexWrap: 'wrap', gap: 6 }}>
        {tags.map((t, i) => (
          <span key={t} style={{
            padding: '6px 12px', borderRadius: 99,
            background: i === 0
              ? `linear-gradient(180deg, ${CLAY} 0%, ${CLAY_DEEP} 100%)`
              : 'transparent',
            border: i === 0 ? 'none' : `1px solid ${MUTED}30`,
            color: i === 0 ? GLOW : INK,
            ...fraunces(11, 300),
            fontStyle: 'italic',
            boxShadow: i === 0 ? `inset 0 1px 1px ${GLOW}40, 0 1px 2px rgba(60,40,25,0.15)` : 'none',
          }}>{t}</span>
        ))}
      </div>
      <div style={{ padding: '24px 24px 8px', ...fraunces(10, 300), color: MUTED, letterSpacing: 2, textTransform: 'uppercase' }}>
        tracks — {results.length}
      </div>
      <div>
        {results.map((r, i) => (
          <React.Fragment key={i}>
            <div style={{
              padding: '13px 24px', display: 'flex', alignItems: 'center', gap: 14,
            }}>
              <div style={{ ...fraunces(11, 300), color: MUTED, width: 18 }}>{String(i+1).padStart(2,'0')}</div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ ...fraunces(19, 300, 144, 100), color: INK, lineHeight: 1.1, fontStyle: 'italic' }}>{r.title}</div>
                <div style={{ ...fraunces(11, 300), color: MUTED, marginTop: 3, letterSpacing: 1, textTransform: 'lowercase' }}>{r.artist} · {r.plays}</div>
              </div>
              <MiniWaveform accent={i === 0}/>
            </div>
            {i < results.length - 1 && <SoftRule/>}
          </React.Fragment>
        ))}
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────
// PROFILE
// ────────────────────────────────────────────────────────────
function ProfileScreen() {
  const tracks = [
    { title: 'Lowtide', date: 'apr 22', plays: '1.2K', live: true },
    { title: 'Hush room', date: 'mar 09', plays: '844' },
    { title: 'Bone china', date: 'feb 14', plays: '2.1K' },
    { title: 'Curfew', date: 'jan 30', plays: '512' },
    { title: 'Brittle', date: 'dec 18', plays: '1.8K' },
  ];
  return (
    <div style={{
      flex: 1, padding: '8px 0 110px',
      background: `radial-gradient(ellipse at 50% 0%, ${SAND} 0%, ${SAND_DEEP} 100%)`,
    }}>
      <div style={{ padding: '16px 24px 0', display: 'flex', justifyContent: 'flex-end', gap: 16 }}>
        <span style={{ ...fraunces(12, 300), color: MUTED, fontStyle: 'italic' }}>edit</span>
        <span style={{ ...fraunces(12, 300), color: MUTED, fontStyle: 'italic' }}>settings</span>
      </div>

      <div style={{ padding: '20px 24px 0', display: 'flex', alignItems: 'flex-end', gap: 18 }}>
        <div style={{
          width: 96, height: 96, borderRadius: '50%',
          background: `radial-gradient(circle at 35% 30%, ${SAND} 0%, ${CLAY} 60%, ${CLAY_DEEP} 100%)`,
          boxShadow: `inset -3px -5px 8px rgba(60,40,25,0.35), inset 2px 3px 4px ${GLOW}80, 0 6px 12px rgba(60,40,25,0.2)`,
          flexShrink: 0,
        }}/>
        <div>
          <div style={{ ...fraunces(38, 300, 144, 100), color: INK, lineHeight: 1, fontStyle: 'italic' }}>moss hall</div>
          <div style={{ ...fraunces(12, 300), color: MUTED, marginTop: 6, letterSpacing: 1 }}>@moss</div>
        </div>
      </div>

      <div style={{ padding: '20px 24px 0', ...fraunces(15, 300), color: INK, lineHeight: 1.5, maxWidth: 320 }}>
        kitchen recordings, slow mixes. four stems at a time. brooklyn / nowhere.
      </div>

      <div style={{
        margin: '22px 24px 0',
        background: `linear-gradient(135deg, ${SAND} 0%, ${SAND_DEEP}60 100%)`,
        border: `1px solid ${MUTED}20`,
        borderRadius: 18,
        display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)',
        boxShadow: `inset 0 1px 1px ${GLOW}50`,
        overflow: 'hidden',
      }}>
        {[['12','tracks'],['8.4K','plays'],['421','waves']].map(([n,l], i) => (
          <div key={l} style={{
            padding: '14px 0', textAlign: 'center',
            borderRight: i < 2 ? `1px solid ${MUTED}20` : 'none',
          }}>
            <div style={{ ...fraunces(26, 300, 144, 100), color: INK, lineHeight: 1, fontStyle: 'italic' }}>{n}</div>
            <div style={{ ...fraunces(10, 300), color: MUTED, marginTop: 4, letterSpacing: 1.5, textTransform: 'lowercase' }}>{l}</div>
          </div>
        ))}
      </div>

      <div style={{ display: 'flex', padding: '24px 24px 0', gap: 22, ...fraunces(13, 300), fontStyle: 'italic' }}>
        <span style={{ color: INK, borderBottom: `1.5px solid ${ACCENT}`, paddingBottom: 4 }}>uploads</span>
        <span style={{ color: MUTED }}>waves</span>
        <span style={{ color: MUTED }}>liked</span>
      </div>

      <div style={{ marginTop: 6 }}>
        {tracks.map((t, i) => (
          <React.Fragment key={i}>
            <div style={{
              padding: '14px 24px', display: 'flex', alignItems: 'center', gap: 14,
            }}>
              <div style={{ flex: 1 }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                  <span style={{ ...fraunces(19, 300, 144, 100), color: INK, lineHeight: 1.1, fontStyle: 'italic' }}>{t.title}</span>
                  {t.live && <span style={{
                    ...fraunces(9, 400),
                    letterSpacing: 1.5, color: GLOW,
                    background: `linear-gradient(180deg, ${ACCENT} 0%, ${CLAY_DEEP} 100%)`,
                    padding: '2px 7px', borderRadius: 99,
                    textTransform: 'uppercase',
                  }}>live</span>}
                </div>
                <div style={{ ...fraunces(11, 300), color: MUTED, marginTop: 3, letterSpacing: 1 }}>{t.date} · {t.plays} plays</div>
              </div>
              <button style={{
                width: 36, height: 36, borderRadius: '50%',
                background: `radial-gradient(circle at 35% 30%, ${CLAY} 0%, ${CLAY_DEEP} 80%)`,
                border: 'none',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                cursor: 'pointer',
                boxShadow: `inset -1px -2px 3px rgba(40,25,15,0.4), inset 1px 1px 2px ${GLOW}50, 0 2px 4px rgba(60,40,25,0.15)`,
              }}>
                <svg width="10" height="10" viewBox="0 0 10 10"><polygon points="2,1 2,9 8,5" fill={GLOW}/></svg>
              </button>
            </div>
            {i < tracks.length - 1 && <SoftRule/>}
          </React.Fragment>
        ))}
      </div>
    </div>
  );
}

Object.assign(window, {
  StemPlayer, TabBar, StatusBar,
  PlayScreen, HomeScreen, UploadEmpty, UploadFilled, SearchScreen, ProfileScreen,
  WWAV_INK: INK, WWAV_PAPER: SAND, WWAV_ACCENT: ACCENT,
});
