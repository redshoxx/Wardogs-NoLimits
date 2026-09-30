# Wardogs NoLimits

Professionelle responsive Community-Website für **WNLD Elite PMC / Wardogs NoLimits**.

## Lokal starten

```bash
git clone https://github.com/redshoxx/Wardogs-NoLimits.git
cd Wardogs-NoLimits
npm install
npm run dev
```

Danach die lokale Vite-Adresse im Browser öffnen, normalerweise:

```text
http://localhost:5173
```

## Build testen

```bash
npm run build
npm run preview
```

## Serverdaten ändern

Die zentralen Werte liegen oben in `app.js`:

- `discordUrl`
- `serverIp`
- `currentPlayers`
- `maxPlayers`
- `map`

## Design

- responsive Desktop / Tablet / Mobile
- dunkles neutrales Military-Design ohne dominanten Blauton
- Live-Server-Panel
- IP-Copy-Funktion
- mobile Navigation
- dezente Scroll-Reveals
- barriereärmere Fokus- und Reduced-Motion-Unterstützung

> Hinweis: Der Discord-Link ist aktuell auf `https://discord.com/` gesetzt. Für den finalen Join-Button bitte den echten Invite-Link in `app.js` eintragen.
