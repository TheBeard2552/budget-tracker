# Home Hub

A **home management** app with spend tracking, company standardization, and a household calendar that **syncs with Google Calendar** (Gmail).

## Features

- Shared **6-digit PIN** unlocks the same home on any device
- Home calendar with person colors: **Jared · Tessa · Poppy · Griffy · Family**
- Two-way **Google Calendar** sync (creates/uses a `Home Hub` calendar in your Gmail account)
- Weekly spend tracking with categories, companies, and a full transactions page
- Manual entries + CSV statement import
- Data stored in a free Supabase Postgres project

## Run locally

```bash
python3 -m http.server 8080
```

Open http://127.0.0.1:8080

## Google Calendar setup (Gmail)

1. In [Google Cloud Console](https://console.cloud.google.com/), create/select a project.
2. Enable **Google Calendar API**.
3. Create an **OAuth 2.0 Client ID** (application type: **Web application**).
4. Under **Authorized JavaScript origins**, add:
   - `http://127.0.0.1:8080`
   - your production origin (if deployed)
5. Copy the Client ID into `config.js` as `googleClientId`.
6. In the app, click **Connect Google Calendar** and approve access.

Events are color-coded the same way in Home Hub and Google Calendar.

## First-time setup in the app

1. On device A, choose **Create new** and pick a 6-digit PIN.
2. Set your weekly budget.
3. On device B, open the same site and **Unlock** with that same PIN.

Use **Settings → Switch device / lock** to clear the PIN from a browser.

## Cloud backend

- Project: `budget-tracker` on Supabase free tier  
- Client config: `config.js` (URL + anon key + optional Google Client ID)  
- Schema / RPCs: `supabase/migrations/`

Tables are not exposed to the client. All reads/writes go through RPCs that require the PIN.
