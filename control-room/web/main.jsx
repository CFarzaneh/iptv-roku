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
  profile: <><circle cx="12" cy="8" r="3.5"/><path d="M5 20a7 7 0 0 1 14 0"/></>,
  refresh: <><path d="M20 7v5h-5M4 17v-5h5"/><path d="M6 6a8 8 0 0 1 14 6M4 12a8 8 0 0 0 14 6"/></>,
  sidebar: <><rect x="2.5" y="3.5" width="19" height="17" rx="2.5"/><path d="M9 3.5v17"/><path className="sidebar-chevron" d="m16.5 8.5-3.5 3.5 3.5 3.5"/></>,
})[name]}</svg>;
const number = (value, divisor = 1) => value == null ? '—' : (value / divisor).toLocaleString(undefined, { maximumFractionDigits: 1 });
const stateName = value => ({ idle: 'Idle', tuning: 'Tuning', playing: 'Playing', buffering: 'Buffering', paused: 'Paused', error: 'Playback error', stopped: 'Stopped' })[value] || 'Unknown';
const lastReport = value => value ? `Last report: ${new Date(value).toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' })}` : 'No reports yet';

function App() {
  const [ready, setReady] = useState(false), [configured, setConfigured] = useState(false);
  const [signedIn, setSignedIn] = useState(false), [error, setError] = useState('');
  const [devices, setDevices] = useState([]), [selected, setSelected] = useState(null);
  const [devicesLoaded, setDevicesLoaded] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => localStorage.getItem('device-sidebar-collapsed') === 'true');
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false);
  const [compactViewport, setCompactViewport] = useState(() => window.matchMedia('(max-width: 850px)').matches);
  const [selectionRevision, setSelectionRevision] = useState(0);
  const [tab, setTab] = useState('channels'), [categories, setCategories] = useState([]);
  const [category, setCategory] = useState(''), [query, setQuery] = useState('');
  const [page, setPage] = useState(null), [loading, setLoading] = useState(false), [notice, setNotice] = useState('');
  const [providerType, setProviderType] = useState('xtream');
  const [link, setLink] = useState('Connecting');
  const pending = useRef(new Map()), catalogGeneration = useRef(0);
  const manualSelection = useRef(false);
  const defaultSelectionSettled = useRef(false);
  const selectedRef = useRef(selected); selectedRef.current = selected;
  const device = devices.find(d => d.id === selected) || devices[0];
  const snapshot = device?.snapshot, metrics = snapshot?.metrics || {};
  const online = Boolean(device?.online && link === 'Connected');

  useEffect(() => { auth.initialize().then(c => { setConfigured(c); setSignedIn(auth.authenticated()); }).catch(e => setError(e.message)).finally(() => setReady(true)); }, []);
  useEffect(() => { localStorage.setItem('device-sidebar-collapsed', String(sidebarCollapsed)); }, [sidebarCollapsed]);
  useEffect(() => {
    const media = window.matchMedia('(max-width: 850px)');
    const changed = () => { setCompactViewport(media.matches); setMobileSidebarOpen(false); };
    media.addEventListener('change', changed);
    return () => media.removeEventListener('change', changed);
  }, []);
  useEffect(() => {
    if (devices.length && !devices.some(d => d.id === selected)) setSelected(devices[0].id);
  }, [devices, selected]);
  useEffect(() => {
    if (!signedIn) return;
    const controller = new AbortController();
    (async () => {
      let cursor = '';
      while (!controller.signal.aborted) {
        try {
          const data = await auth.api(`/events?cursor=${encodeURIComponent(cursor)}`, null, controller.signal);
          cursor = data.cursor; setDevices(data.devices); setDevicesLoaded(true); setLink('Connected');
          if (!manualSelection.current && !defaultSelectionSettled.current && data.devices.length) {
            const firstOnline = data.devices.find(d => d.id === 'my-roku' && d.online) || data.devices.find(d => d.online);
            if (firstOnline) {
              defaultSelectionSettled.current = true;
              setSelected(firstOnline.id);
            } else if (!selectedRef.current || !data.devices.some(d => d.id === selectedRef.current)) {
              setSelected((data.devices.find(d => d.id === 'my-roku') || data.devices[0]).id);
            }
          }
          for (const d of data.devices) for (const result of d.results || []) {
            const p = pending.current.get(result.requestId);
            if (p && p.deviceId === d.id && !['received', 'tuning'].includes(result.status)) {
              pending.current.delete(result.requestId); clearTimeout(p.timer);
              if (['failed', 'stale', 'expired'].includes(result.status)) {
                const failure = Error(result.status === 'expired' ? 'The Roku did not confirm the request in time.' : 'The Roku could not complete the request. Refresh and try again.');
                failure.code = result.code;
                p.reject(failure);
              }
              else p.resolve(result);
            }
          }
          await new Promise(resolve => setTimeout(resolve, document.hidden ? 10000 : 2500));
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
  useEffect(() => {
    if (device?.id === selected && online) loadCatalog('categories', '', 0);
  }, [selected, online, selectionRevision]);

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
    manualSelection.current = true;
    setMobileSidebarOpen(false);
    catalogGeneration.current++; setLoading(false); setSelected(id); setSelectionRevision(revision => revision + 1); setCategories([]); setPage(null); setCategory(''); setQuery(''); setNotice(''); setError('');
  }
  function selectCard(id) {
    if (window.getSelection()?.toString()) return;
    chooseDevice(id);
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
    const wasConfigured = Boolean(snapshot?.provider?.configured);
    setNotice('Validating provider settings on the Roku…'); setError('');
    try { await request('provider-config', values); form.reset(); setProviderType('xtream'); setNotice(wasConfigured ? 'Provider settings saved. Reopen the IPTV app to use them.' : 'Provider settings saved. Channels will load on the Roku shortly.'); }
    catch (e) {
      setNotice('');
      setError(e.code === 'PROVIDER_ERROR'
        ? values.providerType === 'm3u'
          ? 'The Roku could not load channels from this playlist URL. Enter the complete M3U URL.'
          : 'The Roku could not validate this account. Check the server address, username, and password.'
        : e.message);
    }
  }
  if (!ready || (signedIn && !devicesLoaded)) return <div className="entry"><Brand/><p role="status">Loading…</p>{error && <div className="alert" role="alert">{error}</div>}</div>;
  if (!signedIn) return <div className="login"><main className="login-panel"><div className="login-top"><Brand/></div><div className="login-copy"><span className="eyebrow">DEVICE ADMINISTRATION</span><h1>Sign in</h1><p>View Roku status, change channels, and manage provider settings.</p></div>{error && <div role="alert" className="alert">{error}</div>}{configured ? <button className="primary" onClick={() => auth.login().catch(e => setError(e.message))}>Continue to sign in <Icon name="arrow" size={17}/></button> : <div className="setup">Sign-in is unavailable. Try again shortly.</div>}</main></div>;
  if (!devices.length) return <div className="shell"><AppHeader/><main className="workspace"><div className="page-heading"><h1>Devices</h1></div>{error && <div className="alert" role="alert">{error}</div>}<section className="panel empty"><Icon name="tv" size={36}/><h2>No devices yet</h2><p>Open IPTV Player on a Roku to connect.</p></section></main></div>;

  return <div className="shell"><AppHeader/>
    <div className={`dashboard-layout ${sidebarCollapsed ? 'sidebar-collapsed' : ''}`}>
      <aside className={`device-sidebar ${mobileSidebarOpen ? 'open' : ''}`} id="device-sidebar" aria-label="Roku devices"><div className="device-sidebar-inner">
        <div className="device-sidebar-heading"><h2>Devices</h2><span>{String(devices.length).padStart(2, '0')}</span></div>
        <div className="device-list">{devices.map(d => {
          const connected = d.online && link === 'Connected';
          return <div key={d.id} role="button" tabIndex={0} onClick={() => selectCard(d.id)} onKeyDown={e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); chooseDevice(d.id); } }} className={`mini-device ${selected === d.id ? 'selected' : ''}`} aria-pressed={selected === d.id}>
            <div className="mini-device-top"><strong>{d.label}</strong><span className={`pill ${connected ? 'is-online' : 'is-offline'}`}><span className={`status-dot ${connected ? 'live' : ''}`}/>{connected ? 'Online' : 'Offline'}</span></div>
            <span className="mini-device-caption">{connected ? stateName(d.snapshot?.state) : 'Last channel'}</span>
            <span className="mini-device-channel">{d.snapshot?.channel?.name || 'No active stream'}</span>
          </div>;
        })}</div>
      </div></aside>
      {mobileSidebarOpen && <button className="device-sidebar-scrim" aria-label="Close devices" onClick={() => setMobileSidebarOpen(false)}/>}
      <main className="workspace dashboard-workspace"><div className="workspace-toolbar"><button className="sidebar-toggle" aria-controls="device-sidebar" aria-expanded={compactViewport ? mobileSidebarOpen : !sidebarCollapsed} aria-label={compactViewport ? mobileSidebarOpen ? 'Close devices' : 'Show devices' : sidebarCollapsed ? 'Show devices' : 'Collapse devices'} onClick={() => compactViewport ? setMobileSidebarOpen(open => !open) : setSidebarCollapsed(collapsed => !collapsed)}><Icon name="sidebar" size={21}/></button></div>
      {error && <div className="alert" role="alert">{error}<button aria-label="Dismiss error" onClick={() => setError('')}>×</button></div>}
      <div className="dashboard-content">
        <section className="selected-device-card" aria-label={`${device.label} status`} key={device.id}>
          <span className="device-icon"><Icon name="tv" size={22}/></span>
          <div className="selected-device-head"><h2>{device.label}</h2><span className={`pill ${online ? 'is-online' : 'is-offline'}`}><span className={`status-dot ${online ? 'live' : ''}`}/>{online ? 'Online' : 'Offline'}</span></div>
          <div className="selected-device-stream"><span className="eyebrow">{online ? stateName(snapshot?.state).toUpperCase() : 'LAST CHANNEL'}</span><strong>{snapshot?.channel?.name || 'No active stream'}</strong><span className="stream-detail">{snapshot?.channel ? `${snapshot.channel.group} · Stream ID ${snapshot.channel.streamId}` : online ? 'Select a channel to begin playback.' : 'Open the IPTV app on this Roku to reconnect.'}</span></div>
          <div className="selected-device-report"><span>Last report</span><strong>{device.lastSeen ? new Date(device.lastSeen).toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' }) : 'No reports yet'}</strong></div>
          <div className="dashboard-metrics" aria-label="Playback metrics">{[
            ['Media downloaded', metrics.sessionBytes == null ? '—' : `${number(metrics.sessionBytes, 1e6)} MB`, 'this app session'],
            ['Download rate', metrics.bytesPerSecond == null ? '—' : `${number(metrics.bytesPerSecond, 1000)} KB/s`, '5-second window'],
            ['Stream bitrate', metrics.bitrate == null ? '—' : `${number(metrics.bitrate, 1e6)} Mb/s`, ''],
            ['Resolution', metrics.width && metrics.height ? `${metrics.width} × ${metrics.height}` : '—', ''],
          ].map(([label, value, unit]) => <div className="dashboard-metric" key={label}><span>{label}</span><strong>{value}</strong><small>{unit}</small></div>)}</div>
        </section>
        <div className="channel-pane" key={`${device.id}-channels`}><div className="channel-pane-head"><h2>Channels</h2></div>
        <div className="tabs"><button className={tab === 'channels' ? 'current' : ''} onClick={() => setTab('channels')}><Icon name="grid" size={17}/>Channels</button><button className={tab === 'settings' ? 'current' : ''} onClick={() => setTab('settings')}><Icon name="settings" size={17}/>Provider settings</button><button className={tab === 'health' ? 'current' : ''} onClick={() => setTab('health')}><Icon name="wave" size={17}/>Playback health</button><button className={tab === 'device' ? 'current' : ''} onClick={() => setTab('device')}><Icon name="tv" size={17}/>Device settings</button></div>
        {notice && <div className="notice" role="status">{notice}</div>}
    {tab === 'channels' && <section className="panel catalog-panel"><div className="catalog-toolbar"><form className="search" onSubmit={e => { e.preventDefault(); loadCatalog('search'); }}><Icon name="search"/><input aria-label="Search channels by name or stream ID" placeholder="Channel name or stream ID…" value={query} onChange={e => setQuery(e.target.value)} disabled={!online}/><button disabled={!online || loading || !query.trim()}>Search</button></form><button className="secondary" disabled={!online || loading} onClick={() => loadCatalog()}><Icon name="refresh" size={16}/>Load categories</button></div>
    <div className="catalog"><nav className="categories" aria-label="Channel categories">{categories.length ? categories.map(c => <button key={c.id} className={category === c.id ? 'chosen' : ''} disabled={loading || !online} onClick={() => { setCategory(c.id); loadCatalog('channels', c.id); }}>{c.name}<Icon name="arrow" size={13}/></button>) : <p>Load categories to browse channels.</p>}</nav><div className="channel-list">{loading ? <div className="empty"><span className="loader"/><h3>Loading channels</h3><p>Reading the Roku provider catalog.</p></div> : page ? <><div className="list-caption"><span>{page.kind === 'search' ? 'SEARCH RESULTS' : 'CHANNELS'}</span><span>{page.total ?? page.channels?.length} {page.incomplete ? 'reported · partial catalog' : 'available'}</span></div>{page.channels?.length ? page.channels.map(ch => <button className="channel-row" key={ch.streamId} disabled={!online} onClick={() => tune(ch)}><span className="channel-avatar">{ch.name.slice(0, 2).toUpperCase()}</span><span><strong>{ch.name}</strong><small>{ch.group} · {ch.streamId}</small></span><span className="watch">{snapshot?.channel?.streamId === ch.streamId ? 'Playing' : 'Play'} <Icon name="arrow" size={14}/></span></button>) : <div className="empty"><h3>No channels found</h3><p>Try another category or search.</p></div>}<div className="pagination"><button disabled={!online || !page.offset} onClick={() => loadCatalog(page.kind, page.categoryId, Math.max(0, page.offset - 100))}>← Previous</button><button disabled={!online || page.offset + (page.channels?.length || 0) >= page.total} onClick={() => loadCatalog(page.kind, page.categoryId, page.offset + 100)}>Next →</button></div></> : <div className="empty"><Icon name="tv" size={34}/><h3>{online ? 'No channels loaded' : 'Device offline'}</h3><p>{online ? 'Load categories or search for a channel.' : 'Open the IPTV app on this Roku to browse channels.'}</p></div>}</div></div></section>}
    {tab === 'settings' && <section className="panel settings"><div><h3>Provider credentials</h3><p>Saved on {device.label} after validation.</p></div><form onSubmit={saveProvider}><label>Provider type<select name="providerType" value={providerType} onChange={e => setProviderType(e.target.value)}><option value="xtream">Xtream account</option><option value="m3u">M3U playlist</option></select></label><label>{providerType === 'm3u' ? 'Complete M3U playlist URL' : 'Server address'}<input required type="url" name="server" autoComplete="off" placeholder="https://…"/></label>{providerType === 'm3u' ? <p className="provider-hint">Use the complete playlist link supplied by your provider, including any credentials in the URL.</p> : <div className="form-row"><label>Username<input required name="username" autoComplete="off"/></label><label>Password<input required type="password" name="password" autoComplete="new-password"/></label></div>}<button className="primary" disabled={!online}>Validate and save on Roku <Icon name="arrow" size={16}/></button></form></section>}
    {tab === 'device' && <DeviceSettings key={device.id} device={device} onSaved={updated => setDevices(current => current.map(d => d.id === updated.id ? { ...d, label: updated.label } : d))}/>}
    {tab === 'health' && <section className="panel health">{[['Startup time',`${number(metrics.startupMs)} ms`],['Buffering events',number(metrics.bufferingCount)],['Buffering time',`${number(metrics.bufferingMs,1000)} s`],['Installed app',snapshot?.appVersion || '—'],['Roku OS',snapshot?.osVersion || '—'],['Playback',stateName(snapshot?.state)]].map(([k,v]) => <div key={k}><span>{k}</span><strong>{v}</strong></div>)}</section>}
        </div>
      </div>
      <footer><span>Media counters exclude network overhead.</span></footer></main>
    </div>
  </div>;
}
function DeviceSettings({ device, onSaved }) {
  const [name, setName] = useState(device.label), [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false), [message, setMessage] = useState(''), [error, setError] = useState('');
  useEffect(() => { if (!dirty) setName(device.label); }, [device.label, dirty]);
  async function save(event) {
    event.preventDefault();
    setSaving(true); setError(''); setMessage('');
    try {
      const updated = await auth.api(`/devices/${device.id}/settings`, { label: name.trim() });
      onSaved(updated); setName(updated.label); setDirty(false); setMessage('Device name saved.');
    } catch (e) { setError(e.message); }
    finally { setSaving(false); }
  }
  return <section className="panel settings device-settings">
    <form onSubmit={save}>
      <label>Device name<input value={name} required maxLength={80} autoComplete="off" disabled={saving} onChange={e => { setName(e.target.value); setDirty(true); setMessage(''); setError(''); }}/></label>
      <button className="primary" disabled={saving || !name.trim() || name.trim() === device.label}>{saving ? 'Saving…' : 'Save name'}</button>
      {message && <p role="status">{message}</p>}
      {error && <div className="alert" role="alert">{error}</div>}
    </form>
  </section>;
}
function Brand() { return <div className="brand"><span className="brand-mark"><Icon name="tv" size={19}/></span><span>IPTV <strong>Player</strong></span></div>; }
function AppHeader() {
  const [accountOpen, setAccountOpen] = useState(false), [menuOpen, setMenuOpen] = useState(false);
  const menu = useRef(null);
  useEffect(() => {
    if (!menuOpen) return;
    const outside = event => { if (!menu.current?.contains(event.target)) setMenuOpen(false); };
    const escape = event => { if (event.key === 'Escape') setMenuOpen(false); };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('keydown', escape);
    return () => { document.removeEventListener('pointerdown', outside); document.removeEventListener('keydown', escape); };
  }, [menuOpen]);
  return <><div className="app-header"><div className="header-inner"><Brand/><div className="profile-control" ref={menu}><button className="profile-trigger" aria-label="Profile" aria-expanded={menuOpen} onClick={() => setMenuOpen(open => !open)}><Icon name="profile" size={20}/></button>{menuOpen && <div className="profile-dropdown"><button onClick={() => { setMenuOpen(false); setAccountOpen(true); }}>Account</button><button onClick={auth.logout}>Sign out</button></div>}</div></div></div>{accountOpen && <AccountPanel onClose={() => setAccountOpen(false)}/>}</>;
}
function AccountPanel({ onClose }) {
  const [account, setAccount] = useState(null), [email, setEmail] = useState(''), [code, setCode] = useState('');
  const [pendingEmail, setPendingEmail] = useState(sessionStorage.getItem('pending-admin-email') || '');
  const [busy, setBusy] = useState(false), [message, setMessage] = useState(''), [failure, setFailure] = useState('');
  async function load() {
    try { const current = await auth.api('/account'); setAccount(current); setEmail(current.email); }
    catch (e) { setFailure(e.message); }
  }
  useEffect(() => { load(); }, []);
  async function run(action, success) {
    setBusy(true); setFailure(''); setMessage('');
    try { await action(); await load(); setMessage(success); }
    catch (e) { setFailure(e.message); }
    finally { setBusy(false); }
  }
  function requestEmail(e) {
    e.preventDefault();
    run(async () => { await auth.api('/account/email', { email: email.trim() });
      setPendingEmail(email.trim()); sessionStorage.setItem('pending-admin-email', email.trim());
    }, `Verification code sent to ${email.trim()}. Your old email works until you verify the new one.`);
  }
  function verifyEmail(e) {
    e.preventDefault();
    run(async () => { await auth.api('/account/verify-email', { code: code.trim() });
      setPendingEmail(''); sessionStorage.removeItem('pending-admin-email'); setCode('');
    }, 'Email verified. Use the new address when you next sign in.');
  }
  async function removePasskey(passkey) {
    if (!window.confirm(`Remove passkey “${passkey.name || 'Unnamed passkey'}”? Add and test your replacement first.`)) return;
    await run(() => auth.api('/account/delete-passkey', { credentialId: passkey.id }), 'Passkey removed.');
  }
  return <div className="account-backdrop" role="presentation" onMouseDown={e => { if (e.target === e.currentTarget) onClose(); }}><section className="account-panel" role="dialog" aria-modal="true" aria-labelledby="account-title"><div className="account-title"><h2 id="account-title">Account</h2><button className="account-close" aria-label="Close account settings" onClick={onClose}>×</button></div>
    {failure && <div className="alert" role="alert">{failure}</div>}{message && <div className="notice" role="status">{message}</div>}
    {!account ? <p className="account-muted">Loading account…</p> : <>
      <div className="account-section"><h3>Sign-in email</h3><p>Current: <strong>{account.email}</strong>{account.emailVerified ? ' · verified' : ' · unverified'}</p><form onSubmit={requestEmail}><label>New email<input required type="email" value={email} onChange={e => setEmail(e.target.value)} autoComplete="email"/></label><button className="secondary" disabled={busy || email.trim() === account.email}>Send verification code</button></form>
      {pendingEmail && <form onSubmit={verifyEmail}><p>Enter the code sent to <strong>{pendingEmail}</strong>.</p><label>Verification code<input required inputMode="numeric" autoComplete="one-time-code" value={code} onChange={e => setCode(e.target.value)}/></label><div className="account-actions"><button className="primary" disabled={busy || !code.trim()}>Verify new email</button><button type="button" className="text-button" disabled={busy} onClick={() => run(() => auth.api('/account/resend-email-code', {}), 'A new code was sent.')}>Resend code</button></div></form>}</div>
      <div className="account-section"><h3>Password</h3><p>We'll send a reset code to your email.</p><a className="secondary" href={auth.passwordResetUrl()} target="_blank" rel="noopener noreferrer">Reset password <Icon name="arrow" size={15}/></a></div>
      <div className="account-section"><h3>Passkeys</h3><p>Add the replacement first, sign out and test it, then remove the old one.</p><div className="account-actions"><a className="secondary" href={auth.passkeyEnrollmentUrl()} target="_blank" rel="noopener noreferrer">Add passkey <Icon name="arrow" size={15}/></a><button className="text-button" disabled={busy} onClick={load}>Refresh list</button></div><div className="passkey-list">{account.passkeys.length ? account.passkeys.map(passkey => <div className="passkey-row" key={passkey.id}><span><strong>{passkey.name || 'Passkey'}</strong><small>{passkey.createdAt ? `Added ${new Date(passkey.createdAt).toLocaleDateString()}` : ''}</small></span><button className="text-button" disabled={busy} onClick={() => removePasskey(passkey)}>Remove</button></div>) : <p>No passkeys registered.</p>}</div></div>
    </>}
  </section></div>;
}
createRoot(document.getElementById('root')).render(<App/>);
