import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import * as auth from './auth';
import './style.css';

const Icon = ({ name, size = 20 }) => <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{({
  tv: <><rect x="3" y="4" width="18" height="13" rx="3"/><path d="M8 21h8m-4-4v4"/></>,
  grid: <><rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/></>,
  wave: <path d="M2 12h4l3-8 5 16 3-8h5"/>,
  search: <><circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/></>,
  arrow: <path d="m9 5 7 7-7 7"/>,
  settings: <><path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="3" fill="currentColor"/><circle cx="16" cy="17" r="3" fill="currentColor"/></>,
  refresh: <><path d="M20 7v5h-5M4 17v-5h5"/><path d="M6 6a8 8 0 0 1 14 6M4 12a8 8 0 0 0 14 6"/></>,
})[name]}</svg>;
const initialDevices = [{ id: 'my-roku', label: 'My Roku' }, { id: 'dads-roku', label: "Dad’s Roku" }];
const number = (value, divisor = 1) => value == null ? '—' : (value / divisor).toLocaleString(undefined, { maximumFractionDigits: 1 });
const stateName = value => ({ idle: 'Ready', tuning: 'Tuning', playing: 'Playing', buffering: 'Buffering', paused: 'Paused', error: 'Playback error', stopped: 'Stopped' })[value] || 'Not reporting';

function App() {
  const [ready, setReady] = useState(false), [configured, setConfigured] = useState(false);
  const [signedIn, setSignedIn] = useState(false), [error, setError] = useState('');
  const [devices, setDevices] = useState(initialDevices), [selected, setSelected] = useState('my-roku');
  const [tab, setTab] = useState('channels'), [categories, setCategories] = useState([]);
  const [category, setCategory] = useState(''), [query, setQuery] = useState('');
  const [page, setPage] = useState(null), [loading, setLoading] = useState(false), [notice, setNotice] = useState('');
  const [link, setLink] = useState('Connecting');
  const pending = useRef(new Map()), catalogGeneration = useRef(0);
  const selectedRef = useRef(selected); selectedRef.current = selected;
  const device = devices.find(d => d.id === selected) || devices[0];
  const snapshot = device?.snapshot, metrics = snapshot?.metrics || {};
  const online = Boolean(device?.online && link === 'Connected');

  useEffect(() => { auth.initialize().then(c => { setConfigured(c); setSignedIn(auth.authenticated()); }).catch(e => setError(e.message)).finally(() => setReady(true)); }, []);
  useEffect(() => {
    if (!signedIn) return;
    const controller = new AbortController();
    (async () => {
      let cursor = '';
      while (!controller.signal.aborted) {
        try {
          const data = await auth.api(`/events?cursor=${encodeURIComponent(cursor)}`, null, controller.signal);
          cursor = data.cursor; setDevices(data.devices); setLink('Connected');
          for (const d of data.devices) for (const result of d.results || []) {
            const p = pending.current.get(result.requestId);
            if (p && p.deviceId === d.id && !['received', 'tuning'].includes(result.status)) {
              pending.current.delete(result.requestId); clearTimeout(p.timer);
              if (['failed', 'stale', 'expired'].includes(result.status)) p.reject(Error(result.status === 'expired' ? 'The Roku did not confirm the request in time.' : 'The Roku could not complete the request. Refresh and try again.'));
              else p.resolve(result);
            }
          }
        } catch (e) {
          if (controller.signal.aborted) break;
          setLink('Reconnecting'); setError(e.message);
          if (!auth.authenticated()) { setSignedIn(false); break; }
          await new Promise(resolve => setTimeout(resolve, 3000));
          cursor = '';
        }
      }
    })();
    return () => { controller.abort(); for (const p of pending.current.values()) { clearTimeout(p.timer); p.reject(Error('Connection closed')); } pending.current.clear(); };
  }, [signedIn]);

  function request(path, body) {
    const requestId = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.current.delete(requestId); reject(Error('The Roku did not respond in time.')); }, 70000);
      pending.current.set(requestId, { resolve, reject, timer, deviceId: selected });
      auth.api(`/devices/${selected}/${path}`, { ...body, requestId }).catch(e => { clearTimeout(timer); pending.current.delete(requestId); reject(e); });
    });
  }
  async function loadCatalog(kind = 'categories', categoryId = category, offset = 0) {
    const generation = ++catalogGeneration.current, deviceId = selected;
    setLoading(true); setError('');
    try {
      const result = await request('catalog-requests', { kind, categoryId, query: kind === 'search' ? query.trim() : '', offset, limit: 100 });
      if (generation !== catalogGeneration.current || deviceId !== selectedRef.current) return;
      if (kind === 'categories') { setCategories(result.data.categories || []); setPage(null); }
      else setPage({ ...result.data, kind, categoryId });
    } catch (e) { if (generation === catalogGeneration.current) setError(e.message); }
    finally { if (generation === catalogGeneration.current) setLoading(false); }
  }
  function chooseDevice(id) {
    catalogGeneration.current++; setLoading(false); setSelected(id); setCategories([]); setPage(null); setCategory(''); setQuery(''); setNotice(''); setError('');
  }
  async function tune(channel) {
    setError(''); setNotice(`Requesting ${channel.name}…`);
    try {
      await request('commands', { type: 'changeChannel', streamId: channel.streamId,
        sourceRevision: page.sourceRevision, catalogRevision: page.catalogRevision, expectedPlaybackRevision: snapshot.playbackRevision });
      setNotice(`${channel.name} is playing.`);
    } catch (e) { setNotice(''); setError(e.message); }
  }
  async function saveProvider(event) {
    event.preventDefault(); const form = event.currentTarget;
    const values = Object.fromEntries(new FormData(form));
    setNotice('Validating provider settings on the Roku…'); setError('');
    const result = request('provider-config', values);
    form.reset();
    try { await result; setNotice('Provider settings saved. They will apply the next time the IPTV app opens.'); }
    catch (e) { setNotice(''); setError(e.message); }
  }
  if (!ready) return <div className="entry"><Brand/><p>Opening your control room…</p></div>;
  if (!signedIn) return <div className="login"><div className="login-art"><Brand/><div className="login-title"><span className="eyebrow">TWO HOMES. ONE PLACE.</span><h1>A little closer<br/>to what’s on.</h1><p>Your channels, your people.<br/>A quieter way to keep everything connected.</p></div><div className="rings"/><span className="login-foot">SIGNAL / PRIVATE IPTV CONTROL ROOM</span></div><main className="login-form"><span className="eyebrow">WELCOME HOME</span><h2>Your control room.</h2><p>Sign in to see your TVs and choose what plays next.</p>{error && <div role="alert" className="alert">{error}</div>}{configured ? <button className="primary" onClick={() => auth.login().catch(e => setError(e.message))}>Sign in securely <Icon name="arrow"/></button> : <div className="setup">Deployment configuration is not connected yet. Add the API and Cognito settings to open your control room.</div>}<small>One private account · Both TVs</small></main></div>;

  return <div className="shell"><aside className="sidebar"><Brand/><span className="nav-label">YOUR SPACE</span><button className="nav-item active" onClick={() => setTab('channels')}><Icon name="grid"/>Control room</button><div className="sidebar-bottom"><span className={`status-dot ${link === 'Connected' ? 'live' : ''}`}/>{link}<button className="text-button" onClick={auth.logout}>Sign out ↗</button></div></aside>
    <main className="workspace"><header><div><span className="eyebrow">YOUR PRIVATE CONTROL ROOM</span><h1>Everything in view<span>.</span></h1><p>Two homes, connected. Choose a TV to take a closer look.</p></div><div className="region">OHIO <span>us-east-2</span></div></header>
    {error && <div className="alert" role="alert">{error}<button aria-label="Dismiss error" onClick={() => setError('')}>×</button></div>}
    <section className="device-grid" aria-label="Your TVs">{devices.map((d, index) => <button key={d.id} onClick={() => chooseDevice(d.id)} className={`device-card ${selected === d.id ? 'selected' : ''}`} aria-pressed={selected === d.id}><div className="device-top"><span className="device-icon"><Icon name="tv" size={24}/></span><span className="pill"><span className={`status-dot ${d.online && link === 'Connected' ? 'live' : ''}`}/>{d.online && link === 'Connected' ? 'Online' : 'Unavailable'}</span></div><span className="device-number">0{index + 1} / ROKU</span><h2>{d.label}</h2><div className="device-bottom"><span>{d.snapshot?.channel?.name || 'Waiting for a connection'}</span><Icon name="arrow" size={17}/></div></button>)}</section>
    <div className="section-title"><h2>{device.label}</h2><span>{device.lastSeen ? `Last report ${new Date(device.lastSeen).toLocaleTimeString()}` : 'No reports yet'}</span></div>
    <section className="now-playing"><div><span className="eyebrow">{online ? stateName(snapshot?.state).toUpperCase() : 'LAST REPORTED STATE'}</span><h2>{snapshot?.channel?.name || 'Ready when you are.'}</h2><p>{snapshot?.channel ? `${snapshot.channel.group} · Channel ${snapshot.channel.streamId}` : 'Open the IPTV app on this Roku to connect.'}</p></div><div className={`waveform ${snapshot?.state === 'playing' && online ? 'playing' : ''}`} aria-hidden="true">{Array.from({ length: 32 }, (_, i) => <i key={i} style={{ height: `${12 + (Math.sin(i * 1.7) + 1) * 28}px`, animationDelay: `${i * 70}ms` }}/>)}</div><span className="direct-label">DIRECT TO ROKU <span>↗</span></span></section>
    <section className="metrics" aria-label="Playback metrics">{[
      ['Media downloaded', number(metrics.sessionBytes, 1e6), 'MB this app session'],
      ['Recent download rate', number(metrics.bytesPerSecond, 1000), 'KB/s · 5 second window'],
      ['Stream bitrate', number(metrics.bitrate, 1e6), 'Mb/s'],
      ['Resolution', metrics.width && metrics.height ? `${metrics.width} × ${metrics.height}` : '—', 'reported by the player'],
    ].map(([label, value, unit]) => <div className="metric" key={label}><span>{label}</span><strong>{value}</strong><small>{unit}</small></div>)}</section>
    <div className="tabs"><button className={tab === 'channels' ? 'current' : ''} onClick={() => setTab('channels')}><Icon name="grid" size={17}/>Channels</button><button className={tab === 'settings' ? 'current' : ''} onClick={() => setTab('settings')}><Icon name="settings" size={17}/>Provider settings</button><button className={tab === 'health' ? 'current' : ''} onClick={() => setTab('health')}><Icon name="wave" size={17}/>Playback health</button></div>
    {notice && <div className="notice" role="status">{notice}</div>}
    {tab === 'channels' && <section className="panel"><div className="catalog-toolbar"><form className="search" onSubmit={e => { e.preventDefault(); loadCatalog('search'); }}><Icon name="search"/><input aria-label="Search channels" placeholder="Find a channel…" value={query} onChange={e => setQuery(e.target.value)} disabled={!online}/><button disabled={!online || loading || !query.trim()}>Search</button></form><button className="secondary" disabled={!online || loading} onClick={() => loadCatalog()}><Icon name="refresh" size={16}/>Load categories</button></div>
    <div className="catalog"><nav className="categories" aria-label="Channel categories">{categories.length ? categories.map(c => <button key={c.id} className={category === c.id ? 'chosen' : ''} disabled={loading || !online} onClick={() => { setCategory(c.id); loadCatalog('channels', c.id); }}>{c.name}<Icon name="arrow" size={13}/></button>) : <p>Load categories<br/>to browse your channels.</p>}</nav><div className="channel-list">{loading ? <div className="empty"><span className="loader"/><h3>Asking your Roku…</h3><p>Channels come straight from its provider catalog.</p></div> : page ? <><div className="list-caption"><span>{page.kind === 'search' ? 'SEARCH RESULTS' : 'CHANNELS'}</span><span>{page.total ?? page.channels?.length} {page.incomplete ? 'reported · partial catalog' : 'available'}</span></div>{page.channels?.length ? page.channels.map(ch => <button className="channel-row" key={ch.streamId} disabled={!online} onClick={() => tune(ch)}><span className="channel-avatar">{ch.name.slice(0, 2).toUpperCase()}</span><span><strong>{ch.name}</strong><small>{ch.group} · {ch.streamId}</small></span><span className="watch">{snapshot?.channel?.streamId === ch.streamId ? 'Playing' : 'Watch'} <Icon name="arrow" size={14}/></span></button>) : <div className="empty"><h3>No channels found.</h3><p>Try another category or search.</p></div>}<div className="pagination"><button disabled={!online || !page.offset} onClick={() => loadCatalog(page.kind, page.categoryId, Math.max(0, page.offset - 100))}>← Previous</button><button disabled={!online || page.offset + (page.channels?.length || 0) >= page.total} onClick={() => loadCatalog(page.kind, page.categoryId, page.offset + 100)}>Next →</button></div></> : <div className="empty"><Icon name="tv" size={38}/><h3>{online ? 'What’s on today?' : 'Your TV is taking a break.'}</h3><p>{online ? 'Load categories or search for a channel to get started.' : 'Open the IPTV app on this Roku. Its channels will be available here when it connects.'}</p></div>}</div></div></section>}
    {tab === 'settings' && <section className="panel settings"><div><h3>Provider credentials</h3><p>Validated and saved on {device.label}. Your current stream continues; saved settings apply when the IPTV app next opens.</p></div><form onSubmit={saveProvider}><label>Provider type<select name="providerType"><option value="xtream">Xtream account</option><option value="m3u">M3U playlist</option></select></label><label>Server or playlist URL<input required type="url" name="server" autoComplete="off" placeholder="https://…"/></label><div className="form-row"><label>Username<input name="username" autoComplete="off"/></label><label>Password<input type="password" name="password" autoComplete="new-password"/></label></div><button className="primary" disabled={!online}>Validate and save on Roku <Icon name="arrow" size={16}/></button></form></section>}
    {tab === 'health' && <section className="panel health">{[['Startup time',`${number(metrics.startupMs)} ms`],['Buffering events',number(metrics.bufferingCount)],['Buffering time',`${number(metrics.bufferingMs,1000)} s`],['Installed app',snapshot?.appVersion || '—'],['Roku OS',snapshot?.osVersion || '—'],['Playback',stateName(snapshot?.state)]].map(([k,v]) => <div key={k}><span>{k}</span><strong>{v}</strong></div>)}</section>}
    <footer><span><span className="status-dot live"/>Video stays between your provider and your Roku.</span><span>Media counters exclude network overhead.</span></footer></main></div>;
}
function Brand() { return <div className="brand"><span className="brand-icon"><i/><i/><i/></span>signal<span className="brand-period">.</span></div>; }
createRoot(document.getElementById('root')).render(<App/>);
