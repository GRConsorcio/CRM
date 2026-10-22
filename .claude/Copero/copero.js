/*
 * Mod menu - Simulador de Carreira (copero.com.ar/juegos/simulador-carrera)
 *
 * Jeito facil: de dois cliques em copero.bat (abre o Chrome ja com o mod e a carreira configurada).
 * Jeito manual: abra o jogo, F12 > Console, cole este arquivo inteiro e aperte Enter
 *   (se o Chrome pedir, digite "allow pasting" e Enter antes de colar).
 *
 * Abrir/fechar o menu: botao redondo no canto inferior direito, ou a tecla Insert.
 * Tudo vale so ate recarregar a pagina. Nada e enviado ao servidor.
 *
 * "Todos os titulos": voce marca a(s) IDADE(S) da temporada; so essas temporadas ganham tudo
 * (passada ou futura). Desmarcou, volta ao que o jogo tinha dado.
 * "Gols/assistencias minimos": valem so das temporadas seguintes ao momento em que voce coloca o valor.
 */
(() => {
  if (window.top !== window) return; // ignora iframes (anuncios)
  if (!/(^|\.)copero\.com\.ar$/.test(location.hostname)) return;
  if (window.__copMod) window.__copMod.destroy();

  const boot = () => {
    const LS = 'copero-mod-v3';
    const defaults = {
      ovrOn: true, ovr: 80,
      bdOn: true, bdMax: 4, bdChance: 30,
      trophyAges: [],
      goalsMin: 0, assistsMin: 0,
      startOn: true, start: [], startQuery: [],
      extraOn: true, extra: ['real-madrid', 'barcelona', 'paris-saint-germain', 'manchester-city', 'liverpool'], extraQuery: [],
      auto: false,
      open: true,
    };
    const cfg = { ...defaults };
    try { Object.assign(cfg, JSON.parse(localStorage.getItem(LS) || '{}')); } catch (e) {}
    if (window.__COPMOD_CFG && typeof window.__COPMOD_CFG === 'object') Object.assign(cfg, window.__COPMOD_CFG); // vindo do launcher
    ['start', 'extra', 'startQuery', 'extraQuery', 'trophyAges'].forEach(k => { if (!Array.isArray(cfg[k])) cfg[k] = defaults[k]; });
    cfg.trophyAges = [...new Set(cfg.trophyAges.map(Number).filter(n => Number.isInteger(n) && n >= 14 && n <= 45))].sort((a, b) => a - b);
    const save = () => { try { localStorage.setItem(LS, JSON.stringify(cfg)); } catch (e) {} };

    // "22", "22-25", "20, 24-26" -> [20,22,...]
    const parseAges = txt => {
      const set = new Set();
      String(txt).split(/[,;\s]+/).forEach(p => {
        const m = /^(\d{1,2})(?:-(\d{1,2}))?$/.exec(p.trim());
        if (!m) return;
        let a = +m[1], b = m[2] ? +m[2] : a;
        if (a > b) [a, b] = [b, a];
        for (let x = Math.max(a, 14); x <= Math.min(b, 45); x++) set.add(x);
      });
      return [...set];
    };

    // ---- acesso ao estado do jogo (useState do React) ----
    const findHook = () => {
      const root = document.getElementById('root');
      const key = root && Object.keys(root).find(k => k.startsWith('__reactContainer') || k.startsWith('__reactFiber'));
      if (!key) return null;
      const seen = new Set();
      let hit = null;
      (function walk(n) {
        if (!n || seen.has(n) || hit) return;
        seen.add(n);
        let s = n.memoizedState, i = 0;
        while (s && i < 30) {
          const v = s.memoizedState;
          if (v && typeof v === 'object' && 'phase' in v && 'player' in v && 'rngState' in v) { hit = s; return; }
          s = s.next; i++;
        }
        walk(n.child); walk(n.sibling);
      })(root[key].current || root[key]);
      return hit;
    };

    // ---- catalogo de clubes (lido do proprio codigo do jogo) ----
    const norm = s => (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
    const catalog = [];
    const byId = new Map();
    const compByTeam = new Map();    // id do clube -> competicao (cup, confederacao)
    const confSecondary = new Set(); // confederacoes que tem torneio continental secundario
    let catStatus = 'carregando lista de clubes...';
    const addTeam = (t, comp) => {
      if (byId.has(t.id)) return;
      const country = (comp && comp.country_fifa_code) || (/teams\/([A-Za-z]{2,4})\//.exec(t.logo_url || '') || [])[1] || '';
      const e = { id: t.id, name: t.name, short: t.short_name || '', logo: t.logo_url || '', country, key: norm(t.name + ' ' + (t.short_name || '') + ' ' + t.id + ' ' + country) };
      catalog.push(e); byId.set(e.id, e);
    };
    const resolveClub = q => {
      const n = norm(q).trim();
      if (!n) return null;
      if (byId.has(String(q).trim())) return String(q).trim();
      let c = catalog.find(t => t.id === n || norm(t.name) === n || norm(t.short) === n);
      if (!c) c = catalog.find(t => norm(t.name).startsWith(n) || norm(t.short).startsWith(n));
      if (!c) { const w = n.split(/\s+/); c = catalog.find(t => w.every(x => t.key.includes(x))); }
      return c ? c.id : null;
    };
    const waitChunkUrl = async () => {
      for (let i = 0; i < 120; i++) { // o arquivo do jogo so e baixado depois que a pagina monta
        const u = performance.getEntriesByType('resource').map(r => r.name).find(n => /CareerSimulatorPage-[\w-]+\.js/.test(n));
        if (u) return u;
        await new Promise(r => setTimeout(r, 500));
      }
      throw new Error('arquivo do jogo nao encontrado');
    };
    (async () => {
      try {
        const txt = await fetch(await waitChunkUrl()).then(r => r.text());
        // competicoes (cada uma com seus clubes) vem como JSON dentro do codigo do jogo
        let comps = null;
        for (let i = txt.indexOf('JSON.parse(`'); i >= 0 && !comps; i = txt.indexOf('JSON.parse(`', i + 1)) {
          const start = i + 12, end = txt.indexOf('`)', start);
          const body = txt.slice(start, end);
          if (!body.includes('"domestic_cup_id"')) continue;
          try { comps = JSON.parse(body); } catch (e) { try { comps = JSON.parse(Function('return `' + body + '`')()); } catch (e2) {} }
        }
        if (comps) {
          for (const c of comps) for (const t of c.teams || []) { compByTeam.set(t.id, c); addTeam(t, c); }
          const cupCount = id => txt.split(id).length - 1;
          for (const c of comps) c.hasCup = !!c.domestic_cup_id && c.domestic_cup_id !== 'usa-us-open' && cupCount(c.domestic_cup_id) >= 2;
          const confs = txt.indexOf('UEFA:{continental_trophies:{');
          if (confs >= 0) {
            const blk = txt.slice(confs, confs + 3000);
            for (const m of blk.matchAll(/([A-Z]+):\{continental_trophies:\{([^}]*(?:\{[^}]*\}[^}]*)*)\}\}/g)) {
              if (m[2].includes('continental_secondary')) confSecondary.add(m[1]);
            }
          }
        }
        const re = /\{"id":"([a-z0-9-]+)","name":"([^"]+)"/g;
        let m;
        while (!comps && (m = re.exec(txt))) { // reserva (so se a leitura acima falhar; pode trazer ligas junto)
          if (byId.has(m[1])) continue;
          const rest = txt.slice(m.index, m.index + 700);
          addTeam({ id: m[1], name: m[2], short_name: (/"short_name":"([^"]*)"/.exec(rest) || [])[1] || '', logo_url: (/"logo_url":"([^"]*)"/.exec(rest) || [])[1] || '' }, null);
        }
        // nomes digitados no launcher -> ids
        for (const [q, list] of [['startQuery', 'start'], ['extraQuery', 'extra']]) {
          for (const name of cfg[q]) { const id = resolveClub(name); if (id && !cfg[list].includes(id)) cfg[list].push(id); }
          cfg[q] = [];
        }
        // ids que o jogo nao conhece (ex.: Bayern nao existe no jogo) so dariam erro
        cfg.start = cfg.start.filter(id => byId.has(id));
        cfg.extra = cfg.extra.filter(id => byId.has(id));
        save();
        catStatus = `${catalog.length} clubes disponíveis`;
      } catch (e) { catStatus = 'lista de clubes indisponível: ' + e.message; }
      renderResults();
    })();

    const origAwards = new Map(); // id da temporada -> premios originais
    const decision = new Map();   // id da temporada -> manter Bola de Ouro?
    const mvFloor = o => (o >= 90 ? 1e8 : o >= 80 ? 2.5e7 : o >= 70 ? 5e6 : 0);
    const countAwards = seasons => seasons.reduce((n, s) => n + (s.awards || []).length, 0);

    const planBallon = st => {
      const out = new Map();
      let kept = 0;
      for (const s of st.seasons) {
        if (!origAwards.has(s.id)) origAwards.set(s.id, (s.awards || []).slice());
        const orig = origAwards.get(s.id);
        if (!orig.includes('ballon_dor')) continue;
        if (!decision.has(s.id)) decision.set(s.id, Math.random() < cfg.bdChance / 100);
        if (decision.get(s.id) && kept < cfg.bdMax) kept++;
        else out.set(s.id, orig.filter(a => a !== 'ballon_dor'));
      }
      return out;
    };

    // aplica um campo novo por temporada (premios/titulos/estatisticas) em seasons, log e totals
    const patchSeasons = (cur, target, field, logField, totalsFn) => {
      const ages = new Map();
      const seasons = cur.seasons.map(s => {
        if (!target.has(s.id)) return s;
        ages.set(s.age, target.get(s.id));
        return { ...s, [field]: target.get(s.id) };
      });
      const log = (cur.log || []).map(l => (l.type === 'season_completed' && ages.has(l.age) && l.payload
        ? { ...l, payload: { ...l.payload, [logField]: ages.get(l.age) } } : l));
      return { ...cur, seasons, log, totals: totalsFn(cur, seasons) };
    };
    const applyAwards = (cur, target) => patchSeasons(cur, target, 'awards', 'awards', (c, ss) =>
      ({ ...c.totals, awards: Math.max(0, (c.totals.awards || 0) + countAwards(ss) - countAwards(c.seasons)) }));

    // ---- titulos de clube: nas idades marcadas, completa tudo o que existia pra aquele clube/ano ----
    // Regras copiadas do proprio jogo: liga e continentais so na 1a divisao; copa so se a competicao tem copa;
    // secundario so em confederacao que tem e se nao ganhou liga/continental na temporada anterior (ou o principal agora);
    // Mundial de Clubes a cada 4 anos (idade 22, 26, 30...).
    // Temporada desmarcada volta aos titulos originais do jogo.
    const origTrophies = new Map();
    const CLUB_ORDER = ['league', 'cup', 'continental_primary', 'continental_secondary', 'club_world_cup'];
    const countTrophies = seasons => seasons.reduce((n, s) => n + (s.trophies || []).length, 0);
    const planTrophies = st => {
      const out = new Map();
      const marks = new Set(cfg.trophyAges);
      let prev = null;
      for (const s of st.seasons.slice().sort((a, b) => a.index - b.index)) {
        if (!origTrophies.has(s.id)) origTrophies.set(s.id, (s.trophies || []).slice());
        const orig = origTrophies.get(s.id);
        let want = orig;
        const comp = compByTeam.get(s.teamId);
        if (marks.has(s.age) && comp && !s.relegated && !s.suspended) {
          const tier1 = s.competitionTier === 1;
          const set = new Set(orig);
          if (tier1) set.add('league');
          if (comp.hasCup) set.add('cup');
          if (tier1) set.add('continental_primary');
          const blocked = set.has('continental_primary') ||
            (prev && prev.teamId === s.teamId && ['league', 'continental_primary', 'continental_secondary'].some(t => prev.trophies.includes(t)));
          if (tier1 && confSecondary.has(comp.confederation) && !blocked) set.add('continental_secondary');
          if (tier1 && s.age > 18 && (s.age - 18) % 4 === 0) set.add('club_world_cup');
          want = [...orig, ...CLUB_ORDER.filter(t => set.has(t) && !orig.includes(t))];
        }
        if (want.length !== (s.trophies || []).length) out.set(s.id, want);
        prev = { teamId: s.teamId, trophies: want };
      }
      return out;
    };
    const applyTrophies = (cur, target) => patchSeasons(cur, target, 'trophies', 'trophies', (c, ss) =>
      ({ ...c.totals, trophies: Math.max(0, (c.totals.trophies || 0) + countTrophies(ss) - countTrophies(c.seasons)) }));

    // ---- gols e assistencias minimos por temporada (goleiro fica de fora; temporada sem jogos tambem) ----
    // Temporadas que existiam antes de o recurso ser ligado ficam como estao.
    const frozenStats = new Set();
    const planStats = st => {
      const out = new Map();
      if (!st.player || st.player.position === 'GK') return out;
      for (const s of st.seasons) {
        const g = s.stats || {};
        if (frozenStats.has(s.id) || !(g.appearances > 0)) continue;
        const goals = Math.max(g.goals || 0, cfg.goalsMin), assists = Math.max(g.assists || 0, cfg.assistsMin);
        if (goals !== (g.goals || 0) || assists !== (g.assists || 0)) out.set(s.id, { ...g, goals, assists });
      }
      return out;
    };
    const applyStats = (cur, target) => {
      let dg = 0, da = 0;
      for (const s of cur.seasons) if (target.has(s.id)) { dg += target.get(s.id).goals - (s.stats.goals || 0); da += target.get(s.id).assists - (s.stats.assists || 0); }
      return patchSeasons(cur, target, 'stats', 'stats', c => ({ ...c.totals, goals: (c.totals.goals || 0) + dg, assists: (c.totals.assists || 0) + da }));
    };

    // injeta clubes nas opcoes do evento atual (oferta inicial ou janela de transferencia)
    const injectClubs = (h, ev, type, prefix, ids) => {
      const have = new Set(ev.options.map(o => o.teamId));
      if (!ids.some(t => !have.has(t))) return;
      h.queue.dispatch(s => {
        const e = s.currentEvent;
        if (!e || e.type !== type) return s;
        const has = new Set(e.options.map(o => o.teamId));
        const extra = ids.filter(t => !has.has(t) && t !== s.currentTeamId).map(t => ({ id: prefix + '-' + t, type: 'join_club', teamId: t }));
        // o id do evento muda junto: a tela so redesenha os cartoes quando o id muda
        return extra.length ? { ...s, currentEvent: { ...e, id: e.id.replace(/(-m)+$/, '') + '-m', options: [...extra, ...e.options] } } : s;
      });
    };

    // clica sozinho em "Comecar carreira" e "Confirmar identidade" (so uma vez por carga da pagina)
    let autoDone = false, lastAuto = 0;
    const autoClick = st => {
      if (!cfg.auto || autoDone) return;
      if (st && st.phase === 'career') { autoDone = true; return; }
      const now = Date.now();
      if (now - lastAuto < 1500) return;
      const btns = [...document.querySelectorAll('button')];
      const b = btns.find(x => /^(Começar carreira|Comenzar carrera|Start career)/i.test((x.innerText || '').trim())) ||
        btns.find(x => /Confirmar identidade|Confirmar identidad|Confirm identity/i.test(x.innerText || ''));
      if (b && !b.disabled) { lastAuto = now; b.click(); }
    };

    let armed = false;
    const tick = () => {
      try {
        const h = findHook();
        autoClick(h && h.memoizedState);
        if (!h) return;
        const st = h.memoizedState;
        // gols/assistencias: o que ja existe quando o recurso esta desligado (ou quando o mod carrega) fica como esta
        if (st.seasons && (!armed || !(cfg.goalsMin > 0 || cfg.assistsMin > 0))) { armed = true; st.seasons.forEach(s => frozenStats.add(s.id)); }
        if (st.player) refreshStatus(st);

        const ev = st.currentEvent;
        if (ev && ev.type === 'academy_offer' && cfg.startOn && cfg.start.length) injectClubs(h, ev, 'academy_offer', 'academy', cfg.start);
        if (ev && ev.type === 'transfer' && cfg.extraOn && cfg.extra.length) injectClubs(h, ev, 'transfer', 'transfer', cfg.extra);

        if (st.phase !== 'career' || !st.player) return;

        if (cfg.ovrOn && st.player.overall < cfg.ovr) {
          h.queue.dispatch(s => ({
            ...s,
            player: { ...s.player, overall: Math.max(s.player.overall, cfg.ovr), marketValue: Math.max(s.player.marketValue, mvFloor(cfg.ovr)) },
            seasons: (s.seasons || []).map(x => ({ ...x, overall: Math.max(x.overall, cfg.ovr), marketValue: Math.max(x.marketValue, mvFloor(cfg.ovr)) })),
          }));
        }

        if (!st.seasons || !st.seasons.length) return;

        if (cfg.bdOn) {
          const plan = planBallon(st);
          if (st.seasons.some(s => plan.has(s.id) && (s.awards || []).includes('ballon_dor'))) {
            h.queue.dispatch(cur => applyAwards(cur, planBallon(cur)));
          }
        }
        if (compByTeam.size && planTrophies(st).size) h.queue.dispatch(cur => applyTrophies(cur, planTrophies(cur)));
        if ((cfg.goalsMin > 0 || cfg.assistsMin > 0) && planStats(st).size) h.queue.dispatch(cur => applyStats(cur, planStats(cur)));
      } catch (e) { console.error('[mod]', e); }
    };

    // ---- interface ----
    const css = document.createElement('style');
    css.textContent = `
      #cop-mod, #cop-mod * { box-sizing: border-box; }
      #cop-mod { position:fixed; right:12px; bottom:60px; z-index:2147483647; width:290px; max-height:calc(100vh - 80px); overflow:auto;
        background:#14141b; color:#e8e8f0; border:1px solid #3a3a52; border-radius:10px; font:12px/1.4 system-ui,sans-serif; box-shadow:0 6px 24px #000a; }
      #cop-mod .cm-h { display:flex; justify-content:space-between; align-items:center; padding:8px 10px; font-weight:600; background:#1e1e2b; border-radius:10px 10px 0 0; position:sticky; top:0; }
      #cop-mod .cm-b { padding:10px; display:grid; gap:8px; }
      #cop-mod label.cm-r { display:flex; gap:6px; align-items:center; }
      #cop-mod input[type=number] { width:56px; margin-left:auto; }
      #cop-mod input[type=text] { width:100%; }
      #cop-mod input, #cop-mod button { font:inherit; }
      #cop-mod .cm-sec { font-weight:600; margin-top:4px; border-top:1px solid #2c2c3e; padding-top:8px; }
      #cop-mod .cm-list { max-height:150px; overflow:auto; border:1px solid #2c2c3e; border-radius:6px; }
      #cop-mod .cm-row { display:flex; align-items:center; gap:6px; padding:4px 6px; border-bottom:1px solid #22222f; }
      #cop-mod .cm-row:last-child { border-bottom:0; }
      #cop-mod .cm-row img { width:16px; height:16px; object-fit:contain; }
      #cop-mod .cm-row .n { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      #cop-mod .cm-row .c { opacity:.55; font-size:10px; }
      #cop-mod .cm-row button { padding:1px 6px; }
      #cop-mod .cm-chips { display:flex; flex-wrap:wrap; gap:4px; min-height:20px; }
      #cop-mod .cm-chip { display:inline-flex; gap:4px; align-items:center; background:#26263a; border-radius:12px; padding:2px 4px 2px 8px; }
      #cop-mod .cm-chip button { border:0; background:none; color:#e8e8f0; cursor:pointer; padding:0 4px; }
      #cop-mod .cm-btns { display:flex; gap:6px; }
      #cop-mod .cm-btns button { flex:1; }
      #cop-mod .cm-dim { opacity:.7; }
      #cop-mod-toggle { position:fixed; right:12px; bottom:12px; z-index:2147483647; width:40px; height:40px; border-radius:50%; border:1px solid #3a3a52;
        background:#1e1e2b; color:#e8e8f0; font:600 18px system-ui,sans-serif; cursor:pointer; box-shadow:0 4px 16px #000a; }
    `;
    document.head.appendChild(css);

    const box = document.createElement('div');
    box.id = 'cop-mod';
    box.innerHTML = `
      <div class="cm-h"><span>Mod menu</span><button id="cm-close" style="border:0;background:none;color:inherit;cursor:pointer;font-size:14px">✕</button></div>
      <div class="cm-b">
        <label class="cm-r"><input type="checkbox" id="cm-ovrOn"> OVR mínimo <input type="number" id="cm-ovr" min="1" max="99"></label>
        <label class="cm-r"><input type="checkbox" id="cm-bdOn"> Limitar Bolas de Ouro <input type="number" id="cm-bdMax" min="0" max="30"></label>
        <label class="cm-r" style="padding-left:22px">Chance de manter (%) <input type="number" id="cm-bdChance" min="0" max="100"></label>
        <label class="cm-r" title="0 = desligado. Vale so das temporadas seguintes ao momento em que voce coloca o valor">Gols mínimos por temporada <input type="number" id="cm-goalsMin" min="0" max="200"></label>
        <label class="cm-r" title="0 = desligado. Vale so das temporadas seguintes ao momento em que voce coloca o valor">Assist. mínimas por temporada <input type="number" id="cm-assistsMin" min="0" max="200"></label>

        <div class="cm-sec">Todos os títulos nas idades marcadas</div>
        <div class="cm-btns"><input type="text" id="cm-ageIn" placeholder="idade (22) ou faixa (22-25)" style="flex:2"><button id="cm-ageAdd">Marcar</button><button id="cm-ageNext" title="marca a temporada que vem depois da ultima ja jogada">Próxima</button></div>
        <div class="cm-chips" id="cm-ages"></div>

        <div class="cm-sec">Clubes</div>
        <input type="text" id="cm-search" placeholder="Pesquisar clube ou país (ex.: Real, ESP, Flamengo)">
        <div class="cm-list" id="cm-results"></div>
        <div class="cm-dim" id="cm-cat"></div>

        <label class="cm-r"><input type="checkbox" id="cm-startOn"> Clube inicial (aparece na oferta dos 16 anos)</label>
        <div class="cm-chips" id="cm-start"></div>
        <label class="cm-r"><input type="checkbox" id="cm-extraOn"> Extras nas janelas de transferência</label>
        <div class="cm-chips" id="cm-extra"></div>

        <div class="cm-btns"><button id="cm-apply">Aplicar</button><button id="cm-restore" title="devolve as Bolas de Ouro e os titulos que o jogo tinha dado e desliga essas regras">Restaurar prêmios</button></div>
        <div class="cm-dim" id="cm-status"></div>
      </div>`;
    document.body.appendChild(box);

    const toggle = document.createElement('button');
    toggle.id = 'cop-mod-toggle';
    toggle.title = 'Mod menu (Insert)';
    toggle.textContent = '⚙';
    document.body.appendChild(toggle);

    const $ = id => box.querySelector('#cm-' + id);
    const setOpen = v => { cfg.open = v; box.style.display = v ? '' : 'none'; save(); };
    toggle.onclick = () => setOpen(!cfg.open);
    $('close').onclick = () => setOpen(false);
    const onKey = e => { if (e.key === 'Insert' && !/^(INPUT|TEXTAREA)$/.test((e.target || {}).tagName || '')) setOpen(!cfg.open); };
    window.addEventListener('keydown', onKey);

    const num = (v, lo, hi, d) => { const n = Math.round(Number(v)); return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : d; };
    const load = () => {
      $('ovrOn').checked = cfg.ovrOn; $('ovr').value = cfg.ovr;
      $('bdOn').checked = cfg.bdOn; $('bdMax').value = cfg.bdMax; $('bdChance').value = cfg.bdChance;
      $('goalsMin').value = cfg.goalsMin; $('assistsMin').value = cfg.assistsMin;
      $('startOn').checked = cfg.startOn; $('extraOn').checked = cfg.extraOn;
    };
    const read = () => {
      cfg.ovrOn = $('ovrOn').checked; cfg.ovr = num($('ovr').value, 1, 99, 80);
      cfg.bdOn = $('bdOn').checked; cfg.bdMax = num($('bdMax').value, 0, 30, 4); cfg.bdChance = num($('bdChance').value, 0, 100, 30);
      cfg.goalsMin = num($('goalsMin').value, 0, 200, 0); cfg.assistsMin = num($('assistsMin').value, 0, 200, 0);
      cfg.startOn = $('startOn').checked; cfg.extraOn = $('extraOn').checked;
      save(); load();
    };

    // ---- idades marcadas ----
    const renderAges = () => {
      const el = $('ages');
      el.textContent = '';
      if (!cfg.trophyAges.length) { const d = document.createElement('span'); d.className = 'cm-dim'; d.textContent = 'nenhuma idade marcada'; el.appendChild(d); return; }
      cfg.trophyAges.forEach(age => {
        const c = document.createElement('span'); c.className = 'cm-chip';
        const n = document.createElement('span'); n.textContent = age + ' anos';
        const x = document.createElement('button'); x.textContent = '✕'; x.title = 'desmarcar (volta ao que o jogo deu)';
        x.onclick = () => { cfg.trophyAges = cfg.trophyAges.filter(a => a !== age); save(); renderAges(); };
        c.append(n, x); el.appendChild(c);
      });
    };
    const addAges = list => {
      cfg.trophyAges = [...new Set([...cfg.trophyAges, ...list])].sort((a, b) => a - b);
      save(); renderAges();
    };
    $('ageAdd').onclick = () => { addAges(parseAges($('ageIn').value)); $('ageIn').value = ''; };
    $('ageIn').onkeydown = e => { if (e.key === 'Enter') $('ageAdd').click(); };
    $('ageNext').onclick = () => {
      const h = findHook();
      const ages = h && h.memoizedState.seasons ? h.memoizedState.seasons.map(s => s.age) : [];
      addAges([ages.length ? Math.max(...ages) + 1 : 16]);
    };

    const clubName = id => (byId.get(id) || { name: id }).name;
    const renderChips = which => {
      const el = $(which);
      el.textContent = '';
      if (!cfg[which].length) { const d = document.createElement('span'); d.className = 'cm-dim'; d.textContent = 'nenhum'; el.appendChild(d); return; }
      cfg[which].forEach(id => {
        const c = document.createElement('span'); c.className = 'cm-chip';
        const n = document.createElement('span'); n.textContent = clubName(id);
        const x = document.createElement('button'); x.textContent = '✕'; x.title = 'remover';
        x.onclick = () => { cfg[which] = cfg[which].filter(t => t !== id); save(); renderChips(which); renderResults(); };
        c.append(n, x); el.appendChild(c);
      });
    };
    function renderResults() {
      const q = norm($('search').value).trim();
      const list = $('results');
      list.textContent = '';
      $('cat').textContent = catStatus;
      if (!q) { const d = document.createElement('div'); d.className = 'cm-row cm-dim'; d.textContent = 'Digite para pesquisar'; list.appendChild(d); renderChips('start'); renderChips('extra'); return; }
      const words = q.split(/\s+/);
      const hits = catalog.filter(t => words.every(w => t.key.includes(w))).slice(0, 40);
      if (!hits.length) { const d = document.createElement('div'); d.className = 'cm-row cm-dim'; d.textContent = 'Nada encontrado'; list.appendChild(d); }
      hits.forEach(t => {
        const row = document.createElement('div'); row.className = 'cm-row';
        const img = document.createElement('img'); img.src = t.logo; img.onerror = () => { img.style.visibility = 'hidden'; };
        const n = document.createElement('span'); n.className = 'n'; n.textContent = t.name; n.title = t.id;
        const c = document.createElement('span'); c.className = 'c'; c.textContent = t.country;
        const mk = (label, which) => {
          const b = document.createElement('button');
          const on = cfg[which].includes(t.id);
          b.textContent = on ? '✓ ' + label : label; b.disabled = on;
          b.onclick = () => { cfg[which].push(t.id); save(); renderChips(which); renderResults(); };
          return b;
        };
        row.append(img, n, c, mk('Inicial', 'start'), mk('Extra', 'extra'));
        list.appendChild(row);
      });
      renderChips('start'); renderChips('extra');
    }
    function refreshStatus(st) {
      const bd = (st.seasons || []).filter(s => (s.awards || []).includes('ballon_dor')).length;
      const orig = [...origAwards.values()].filter(a => a.includes('ballon_dor')).length;
      $('status').textContent = `OVR ${st.player.overall} · idade ${st.player.age} · Bolas de Ouro ${bd} (jogo deu ${Math.max(bd, orig)})`;
    }

    ['ovrOn', 'bdOn', 'startOn', 'extraOn', 'ovr', 'bdMax', 'bdChance', 'goalsMin', 'assistsMin'].forEach(id => { $(id).onchange = read; });
    $('search').oninput = renderResults;
    $('apply').onclick = () => { read(); decision.clear(); tick(); };
    $('restore').onclick = () => {
      cfg.bdOn = false; cfg.trophyAges = []; save(); load(); renderAges();
      const h = findHook();
      if (!h) return;
      // os titulos voltam sozinhos (nenhuma idade marcada); as Bolas de Ouro voltam aqui
      h.queue.dispatch(cur => applyAwards(cur, new Map([...origAwards].filter(([id]) => cur.seasons.some(s => s.id === id)))));
    };
    load(); renderAges(); renderResults(); setOpen(cfg.open);

    const timer = setInterval(tick, 400);
    window.__copMod = {
      cfg,
      destroy() { clearInterval(timer); window.removeEventListener('keydown', onKey); box.remove(); toggle.remove(); css.remove(); delete window.__copMod; },
    };
    console.log('[mod] menu carregado');
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();
