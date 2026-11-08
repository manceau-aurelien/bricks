# 🧱 BRICKS — l'anglais brique par brique / French, brick by brick

Un jeu incrémental pour apprendre une langue : on débloque des **briques de vocabulaire** (10 mots par thème), on les renforce avec des **attributs** (orthographe, phrases affirmatives, négatives, questions)… et le temps les **érode** : il faut réviser au bon moment pour qu'elles restent solides.

An incremental game to learn a language: unlock **vocabulary bricks** (10 words per theme), strengthen them with **upgrades** (spelling, affirmative, negative, questions)… while time **erodes** them — review at the right moment to keep them solid.

## Parcours / Paths
- 🇬🇧 **J'apprends l'anglais** — interface en français
- 🇫🇷 **I'm learning French** — interface in American English

Plusieurs profils peuvent jouer sur le même appareil. La progression est enregistrée dans le navigateur (localStorage) : rien n'est partagé entre profils, parcours ou appareils.

## Jouer / Play
Ouvrir la page GitHub Pages du dépôt, ou ouvrir `index.html` dans un navigateur (Chrome / Edge / Safari). Aucune installation, aucune dépendance.

## Structure
- `index.html` — page
- `css/style.css` — styles (ordinateur, tablette, téléphone)
- `js/i18n.js` — textes de l'interface (fr / en-US)
- `js/data-en.js`, `js/data-fr.js` — contenu pédagogique des deux parcours
- `js/game.js` — moteur du jeu
