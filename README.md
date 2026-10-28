# Event Registration app — source code

A simple event registration web app that runs in any modern browser.

- **Register** page (`/`) — a form with Full name, Email, Phone number and Company name
  (required) and Details (optional). Fields are validated, and the attendee sees a
  confirmation after submitting. An attendee pass next to the form fills in as they type.
- **Admin** page (`/?view=admin`) — every submitted form is shown as its own entry card
  with name, company, email, phone, details and submission time, newest first, with a
  total count and a delete button (asks for confirmation).

Built with **React 19 + TypeScript + Vite + Tailwind CSS**.

## Where the app's code is

| File | What it contains |
| --- | --- |
| `src/pages/home.tsx` | The registration form and validation, the attendee pass, and the admin view |
| `src/components/app-shell.tsx` | The top bar with the Register / Admin navigation |
| `src/data/registrations.ts` | The `Registration` data shape and 10 sample registrations |
| `src/index.css` | Colors and theme (light and dark) |

Everything else is the standard project template (UI components and build configuration).

## Run it on your computer

Requires [Node.js](https://nodejs.org/) 20 or later.

```bash
npm install
npm run dev
```

Then open the address Vite prints (usually http://localhost:5173).

## Build it for hosting

```bash
npm run build
```

This produces a static website in the `dist/` folder that you can host on any static web
host (for example Azure Static Web Apps, Azure App Service, IIS or Nginx). The admin view
is selected with a query string (`?view=admin`), so no server rewrite rules are needed.

## Important: where registrations are stored

This version keeps registrations **in the browser's memory only**:

- they are lost when the page is refreshed or closed, and
- people registering on their own devices are not visible in someone else's admin view.

To use it for a real event, connect it to a data store:

1. **SharePoint list (Microsoft 365)** — ask Copilot to "save this app's data to
   SharePoint". Registrations are then stored in a SharePoint list, and SharePoint
   permissions control who can see them.
2. **Your own backend** — replace the `useState` list in `HomePage`
   (`src/pages/home.tsx`) with calls to your API (save on submit, load in the admin view,
   delete from the admin view).

To start with an empty list instead of the sample registrations, change
`sampleRegistrations` in `src/data/registrations.ts` to an empty array (`[]`).

## Who can open the admin view

Anyone who can open the app can open the Admin view. Before collecting real attendee
data, restrict it — for example with SharePoint list permissions, or with sign-in on the
site that hosts the app.

## Running outside Microsoft 365

The published version of this app runs inside Microsoft 365. When you run it anywhere
else (for example `npm run dev` on your PC), the browser console may show
`[channel] Handshake timed out` about 30 seconds after the page loads. That message is
harmless: it refers to the Microsoft 365 host connection, which only exists when the app
runs there. The form and admin view work normally.

`ms.config.json` links this project to your published app. To change the published
version, ask Copilot to update the app, or use the Microsoft managed apps CLI
(`npm install -g @microsoft/managed-apps-cli`, then `ms --help`).
