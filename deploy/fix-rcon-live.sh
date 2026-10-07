#!/usr/bin/env bash
set -euo pipefail
APP=/opt/nolimits-balancer
cd "$APP"
STAMP="$(date +%Y%m%d-%H%M%S)"
cp rcon.js "rcon.js.bak-$STAMP"
cp server.js "server.js.bak-$STAMP"
cp public/app.js "public/app.js.bak-$STAMP"

cat > rcon.js <<'RCONJS'
import {
  upsertPlayer, markPlayerOffline, listPlayers, activeParties, getSettings, logEvent,
  startMatch, snapshotMatchPlayer, completeMatch
} from './db.js';
import { computeBalance } from './balancer.js';
import { learnFromCompletedMatch } from './learner.js';

const baseUrl = process.env.WARDOGS_RCON_URL?.trim()?.replace(/\/+$/,'');
const token = process.env.WARDOGS_RCON_TOKEN?.trim();
const enabled = Boolean(baseUrl && token);

const CAPABILITY_REFRESH_MS = 5 * 60 * 1000;
const MIN_BETWEEN_RCON_REQUESTS_MS = 175;
const MAX_BACKOFF_MS = 60 * 1000;

let timer = null;
let latest = {
  connected:false,
  enabled,
  status:null,
  players:[],
  activeFactions:[],
  capabilities:[],
  capabilityDocument:null,
  lastUpdate:null,
  lastSuccess:null,
  lastError:null,
  latencyMs:null,
  throttled:false,
  retryAt:null
};
let knownIds = new Set();
let currentMatchId = null;
let currentMap = null;
let lastStatus = null;
let lastCapabilityRefresh = 0;
let consecutive429 = 0;
let backoffUntil = 0;
let tickRunning = false;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function request(method,path,body=null){
  if (!enabled) throw new Error('RCON ist nicht konfiguriert');
  const headers = {
    'Authorization': `Bearer ${token}`,
    'Accept':'application/json'
  };
  const init = {method,headers,signal:AbortSignal.timeout(6000)};
  if (body !== null) {
    headers['Content-Type']='application/json';
    init.body=JSON.stringify(body);
  }
  const res=await fetch(baseUrl+path,init);
  const raw=await res.text();
  let data=null;
  try { data=raw?JSON.parse(raw):{}; } catch { data={message:raw}; }
  if (!res.ok) {
    const msg=data?.error?.message || data?.message || `${res.status} ${res.statusText}`;
    const err=new Error(msg);
    err.status=res.status; err.body=data;
    const retryAfter = Number(res.headers.get('retry-after'));
    if (Number.isFinite(retryAfter) && retryAfter > 0) err.retryAfterMs = retryAfter * 1000;
    throw err;
  }
  return data;
}

function liveFactions(status,players){
  const counts = new Map();
  for (const p of players || []) {
    const f = p?.faction;
    if (!f) continue;
    counts.set(f,(counts.get(f)||0)+1);
  }
  return [...counts.entries()].sort((a,b)=>b[1]-a[1]).map(([name])=>name).slice(0,2);
}

async function refreshCapabilities(force=false){
  const now=Date.now();
  if (!force && latest.capabilities.length && now-lastCapabilityRefresh < CAPABILITY_REFRESH_MS) return;
  const capDoc=await request('GET','/v1/capabilities');
  latest.capabilityDocument=capDoc;
  latest.capabilities=capDoc?.routes||[];
  lastCapabilityRefresh=now;
}

export function rconState(){ return latest; }

export async function testRcon(){
  if (!enabled) return {ok:false,error:'WARDOGS_RCON_URL oder TOKEN fehlt'};
  const t=Date.now();
  const status=await request('GET','/v1/status');
  await sleep(MIN_BETWEEN_RCON_REQUESTS_MS);
  const capabilities=await request('GET','/v1/capabilities');
  return {ok:true,latencyMs:Date.now()-t,status,capabilities};
}

export async function startRconWatcher(){
  if (!enabled) {
    latest.lastError='RCON nicht konfiguriert – Demo/Offline-Modus';
    logEvent('warning','rcon','RCON ist noch nicht konfiguriert');
    return;
  }
  await tick().catch(()=>{});
  const ms = Math.max(5000,Number(getSettings().rcon_poll_ms || 5000));
  timer=setInterval(()=>tick().catch(()=>{}),ms);
}
export async function stopRconWatcher(){ if(timer)clearInterval(timer); }

async function tick(){
  if (tickRunning) return;
  if (Date.now() < backoffUntil) return;
  tickRunning=true;
  const t0=Date.now();
  try{
    await refreshCapabilities(false);
    await sleep(MIN_BETWEEN_RCON_REQUESTS_MS);
    const status=await request('GET','/v1/status');
    await sleep(MIN_BETWEEN_RCON_REQUESTS_MS);
    const playerResp=await request('GET','/v1/players');
    const players=Array.isArray(playerResp)?playerResp:(playerResp.players||[]);
    const activeFactions=liveFactions(status,players);

    consecutive429=0;
    backoffUntil=0;
    latest={
      ...latest,
      connected:true,enabled:true,status,players,activeFactions,
      lastUpdate:new Date().toISOString(),lastSuccess:new Date().toISOString(),
      lastError:null,latencyMs:Date.now()-t0,throttled:false,retryAt:null
    };

    const nowIds=new Set(players.map(p=>String(p.steamId)));
    for(const p of players){
      p.steamId=String(p.steamId);
      const joined=!knownIds.has(p.steamId);
      upsertPlayer(p);
      if(joined)logEvent('info','join',`${p.name} ist beigetreten`,{steamId:p.steamId,faction:p.faction});
    }
    for(const oldId of knownIds) if(!nowIds.has(oldId)){
      markPlayerOffline(oldId);
      logEvent('info','leave','Spieler hat den Server verlassen',{steamId:oldId});
    }
    knownIds=nowIds;

    await handleMatchLifecycle(status,players);
    await applyJoinAssignments(players,latest.capabilities,activeFactions);
    lastStatus=status;
  }catch(err){
    const is429=Number(err?.status)===429;
    if(is429){
      consecutive429++;
      const retryMs=Math.min(MAX_BACKOFF_MS,err?.retryAfterMs || (5000*Math.pow(2,Math.min(3,consecutive429-1))));
      backoffUntil=Date.now()+retryMs;
      latest={
        ...latest,
        connected:Boolean(latest.lastSuccess),
        lastError:'RCON Rate Limit (429) – neuer Versuch automatisch',
        lastUpdate:new Date().toISOString(),
        throttled:true,
        retryAt:new Date(backoffUntil).toISOString()
      };
      logEvent('warning','rcon','RCON Rate Limit – Backoff aktiv',{status:429,retryMs});
    }else{
      latest={
        ...latest,
        connected:false,
        lastError:String(err?.message||err),
        lastUpdate:new Date().toISOString(),
        throttled:false,retryAt:null
      };
      logEvent('error','rcon','RCON-Abfrage fehlgeschlagen',{error:latest.lastError,status:err?.status||null});
    }
  }finally{
    tickRunning=false;
  }
}

async function handleMatchLifecycle(status,players){
  const map=status.map||'Unknown';
  const factionNames=liveFactions(status,players);
  const balanceFactions=factionNames.length===2?factionNames:[];
  if(!currentMatchId){
    const balance=computeBalance(balanceFactions);
    currentMatchId=startMatch({
      map,teamA:balance.teamA,teamB:balance.teamB,
      predictionA:balance.prediction[balance.teamA],predictionB:balance.prediction[balance.teamB]
    });
    currentMap=map;
    logEvent('info','match','Match-Tracking gestartet',{matchId:currentMatchId,map});
  }

  const parties=activeParties();
  const memberParty=new Map();
  for(const party of parties)for(const m of party.members)memberParty.set(m.steam_id,party.id);
  for(const p of players)snapshotMatchPlayer(currentMatchId,p,memberParty.get(String(p.steamId))||null);

  if(currentMap && map!==currentMap && lastStatus){
    const oldMatchId=currentMatchId;
    const oldScores=[...(lastStatus.factionScores||[])].sort((a,b)=>(b.score||0)-(a.score||0));
    const winner=oldScores[0]?.name||null;
    completeMatch(oldMatchId,{winnerFaction:winner,scoreA:oldScores[0]?.score??null,scoreB:oldScores[1]?.score??null});
    if(winner){
      try{ learnFromCompletedMatch(oldMatchId); }
      catch(e){logEvent('error','learning','Lernen aus Match fehlgeschlagen',{matchId:oldMatchId,error:String(e?.message||e)});}
    }
    const balance=computeBalance(balanceFactions);
    currentMatchId=startMatch({
      map,teamA:balance.teamA,teamB:balance.teamB,
      predictionA:balance.prediction[balance.teamA],predictionB:balance.prediction[balance.teamB]
    });
    currentMap=map;
    logEvent('info','match','Neue Map erkannt – neues Match gestartet',{matchId:currentMatchId,map});
  }
}

function routeSupportsMove(routes){
  return routes.some(r=>{
    const s=String(r);
    return s==='PATCH /v1/players/{steamId}' || s==='PATCH /v1/players/{id}' || s.startsWith('PATCH /v1/players/{');
  });
}

async function applyJoinAssignments(players,routes,activeFactions){
  const settings=getSettings();
  if(!settings.auto_apply_on_join || !routeSupportsMove(routes))return;
  if(!Array.isArray(activeFactions) || activeFactions.length!==2)return;
  const balance=computeBalance(activeFactions);
  const allRows=listPlayers();
  const rowById=new Map(allRows.map(p=>[p.steam_id,p]));

  for(const p of players){
    const sid=String(p.steamId);
    const desired=balance.assignments[sid];
    if(!desired || desired===p.faction)continue;
    const row=rowById.get(sid);
    const joinedAt=row?.session_started?new Date(row.session_started).getTime():0;
    const withinGrace=joinedAt && Date.now()-joinedAt < Number(settings.join_grace_seconds||45)*1000;
    if(!withinGrace && !settings.auto_mid_match)continue;
    try{
      await request('PATCH',`/v1/players/${encodeURIComponent(sid)}`,{faction:desired});
      try{await request('POST',`/v1/players/${encodeURIComponent(sid)}/kill`,{});}catch{}
      logEvent('success','teamchange',`${p.name}: ${p.faction} → ${desired}`,{steamId:sid,from:p.faction,to:desired});
    }catch(e){
      logEvent('error','teamchange','Automatischer Teamwechsel fehlgeschlagen',{steamId:sid,error:String(e?.message||e)});
    }
  }
}
RCONJS

python3 - <<'PY'
from pathlib import Path
p=Path('server.js')
s=p.read_text(encoding='utf-8')
s=s.replace("  const factionNames=(rcon.status?.factionScores||[]).map(x=>x.name).filter(Boolean);\n  const balance=computeBalance(factionNames);", "  const factionNames=Array.isArray(rcon.activeFactions) && rcon.activeFactions.length===2 ? rcon.activeFactions : [];\n  const balance=computeBalance(factionNames);")
s=s.replace("  const factions=(rcon.status?.factionScores||[]).map(x=>x.name).filter(Boolean);\n  const result=computeBalance(factions);", "  const factions=Array.isArray(rcon.activeFactions) && rcon.activeFactions.length===2 ? rcon.activeFactions : [];\n  const result=computeBalance(factions);")
p.write_text(s,encoding='utf-8')

p=Path('public/app.js')
s=p.read_text(encoding='utf-8')
s=s.replace("  $('round').textContent='RCON: '+(rcon.connected?'LIVE':'DEMO/OFFLINE');", "  $('round').textContent='RCON: '+(rcon.connected?(rcon.throttled?'LIVE / BACKOFF':'LIVE'):'OFFLINE');")
s=s.replace("    <div class=\"status-line\"><span><i class=\"dot ${rcon.connected?'':'bad'}\"></i>Verbindung</span><b>${rcon.connected?'OK':'OFF'}</b></div>", "    <div class=\"status-line\"><span><i class=\"dot ${rcon.connected?'':'bad'}\"></i>Verbindung</span><b>${rcon.connected?(rcon.throttled?'BACKOFF':'OK'):'OFF'}</b></div>")
s=s.replace("load(); setInterval(load,3000);", "load(); setInterval(load,5000);")
p.write_text(s,encoding='utf-8')
PY


# Keep the observation mode explicitly safe.
AUSER="$(grep '^ADMIN_USER=' .env | cut -d= -f2-)"
APASS="$(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2-)"

docker build -q -t nolimits-balancer:latest "$APP" >/dev/null
docker rm -f nolimits-balancer >/dev/null 2>&1 || true
docker run -d --name nolimits-balancer --restart unless-stopped --network host \
  --env-file "$APP/.env" \
  -v "$APP/data:/data" \
  nolimits-balancer:latest >/dev/null

for i in $(seq 1 30); do
  if curl -fsS -u "$AUSER:$APASS" http://127.0.0.1:4180/health 2>/dev/null | grep -q '"ok":true'; then break; fi
  sleep 1
done


echo 'PATCH_OK'
echo 'Warte auf Live-RCON...'
for i in $(seq 1 18); do
  STATE="$(curl -fsS -u "$AUSER:$APASS" http://127.0.0.1:4180/api/state 2>/dev/null || true)"
  if printf '%s' "$STATE" | grep -q '"connected":true'; then
    printf '%s' "$STATE" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["rcon"]; s=r.get("status") or {}; p=s.get("players") or {}; print("RCON_CONNECTED=true"); print("SERVER="+str(s.get("serverName","?"))); print("MAP="+str(s.get("map","?"))); print("PLAYERS="+str(p.get("current","?"))+"/"+str(p.get("max","?"))); print("LIVE_ROWS="+str(len(r.get("players") or []))); print("THROTTLED="+str(bool(r.get("throttled"))).lower()); st=d.get("settings") or {}; print("AUTO_JOIN="+str(bool(st.get("auto_apply_on_join"))).lower()); print("AUTO_MID="+str(bool(st.get("auto_mid_match"))).lower()); print("POLL_MS="+str(st.get("rcon_poll_ms","?")))'
    exit 0
  fi
  sleep 5
done

STATE="$(curl -fsS -u "$AUSER:$APASS" http://127.0.0.1:4180/api/state 2>/dev/null || true)"
printf '%s' "$STATE" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("rcon") or {}; print("RCON_CONNECTED="+str(bool(r.get("connected"))).lower()); print("THROTTLED="+str(bool(r.get("throttled"))).lower()); print("LAST_ERROR="+str(r.get("lastError"))); print("RETRY_AT="+str(r.get("retryAt")))' || true
exit 4