# Téléchargement local d'un extranet authentifié

Outil en deux temps pour récupérer en local le contenu d'un portail qui exige
une connexion (ex. `extranet.nobilia.de`) :

1. **`login`** — ouvre une vraie fenêtre de navigateur, tu te connectes à la
   main, et la session est enregistrée dans un fichier d'état.
   Ton mot de passe n'est jamais écrit sur le disque, seulement les cookies.
2. **`inspect`** *(optionnel)* — sonde le portail et produit un rapport de
   structure, sans rien télécharger. Utile pour régler le `crawl` avant de le
   lancer en grand.
3. **`crawl`** — rejoue cette session sans interface, parcourt le site et
   copie les pages et les fichiers en local. Interruptible et reprenable.

> **À vérifier avant usage.** N'utilise cet outil que sur un compte dont tu as
> le droit de te servir, et consulte les conditions d'utilisation du portail :
> l'aspiration complète d'un extranet partenaire y est souvent interdite, même
> avec des identifiants valides. Le délai entre requêtes est là pour ne pas
> surcharger le serveur — ne le mets pas à zéro sur un site tiers.

## Installation

```bash
cd tools/nobilia-extranet-downloader
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium
```

Si Chromium est déjà présent sur la machine, on peut éviter le téléchargement :

```bash
export PLAYWRIGHT_CHROMIUM_PATH=/chemin/vers/chrome   # ou --browser-path
```

## 1. Se connecter

```bash
python3 download_extranet.py --url https://extranet.nobilia.de/ login
```

Une fenêtre s'ouvre. Tu te connectes (identifiant `0073003_chef` + mot de
passe), tu acceptes l'éventuel bandeau cookies, tu arrives sur la page
d'accueil connectée — puis tu reviens au terminal et tu appuies sur **Entrée**.
La session est écrite dans `state.json`.

Cette étape manuelle est volontaire : elle marche quelle que soit la forme du
formulaire, y compris avec double authentification, SSO ou captcha.

Pour pré-remplir le formulaire automatiquement :

```bash
export EXTRANET_USER=0073003_chef
read -s EXTRANET_PASSWORD && export EXTRANET_PASSWORD   # saisie masquée
python3 download_extranet.py --url https://extranet.nobilia.de/ login --auto
```

## 2. Analyser la structure (optionnel mais recommandé)

```bash
python3 download_extranet.py --url https://extranet.nobilia.de/ inspect --out recon
```

Ne télécharge rien : sonde une douzaine de pages et écrit `recon/report.md`
(lisible) et `recon/report.json` (détaillé). Le rapport donne :

- les **sections** du portail, par fréquence de liens ;
- les **types de fichiers** présents (`.pdf`, `.xlsx`, `.dwg`, …) ;
- les **hôtes** référencés, pour savoir s'il faut un `--allow-host` (CDN) ;
- si la navigation est **construite en JavaScript** — comparaison entre le HTML
  servi et le DOM rendu, page par page ;
- le framework détecté (React, Angular, Vue, SharePoint, …) ;
- une **commande `crawl` suggérée**, adaptée à ce qui a été trouvé.

Le rapport ne contient que des URL et des titres de pages, jamais le contenu.
Relis-le quand même avant de le partager : des URL seules peuvent être
parlantes (noms de clients, références tarifaires).

## 3. Télécharger

```bash
python3 download_extranet.py --url https://extranet.nobilia.de/ crawl --out download
```

Résultat :

```
download/
├── pages/extranet.nobilia.de/...   # pages HTML, telles que rendues (JS inclus)
├── files/extranet.nobilia.de/...   # PDF, images, XLSX, DWG, ZIP...
├── manifest.json                   # état du parcours (permet la reprise)
└── crawl.log
```

L'arborescence locale reproduit celle des URL. Deux pages qui ne diffèrent que
par leur *query string* reçoivent des noms distincts.

### Reprendre après une interruption

Relance exactement la même commande : `manifest.json` mémorise ce qui est déjà
récupéré et ce qui reste en file d'attente. Rien n'est retéléchargé.

Si la session a expiré, le script s'arrête avec un message explicite (code de
sortie `2`) : refais l'étape `login`, puis relance le `crawl`, qui reprendra où
il s'était arrêté.

## Options utiles

| Option | Effet |
| --- | --- |
| `--max-pages 50` | s'arrêter après 50 éléments (utile pour un premier essai) |
| `--max-depth 3` | limiter la profondeur de liens (défaut : 6) |
| `--delay 3` | secondes entre deux requêtes (défaut : 1.5) |
| `--include '/katalog\|/preise'` | ne suivre que les URL correspondant à cette regex |
| `--exclude '/print\|\.zip$'` | ne jamais suivre ces URL |
| `--settle 2` | attendre 2 s de plus par page (sites JS lents) |
| `--wait-until load` | condition de chargement moins stricte que `networkidle` |
| `--allow-host cdn.nobilia.de` | autoriser un domaine supplémentaire (CDN) |
| `--headed` | afficher le navigateur pendant le parcours |

`inspect` accepte `--sample` (nombre de pages sondées, défaut 12) et `--depth`
(profondeur d'échantillonnage, défaut 2).

## Garde-fous intégrés

- Les liens de déconnexion (`logout`, `abmelden`, …) ne sont jamais suivis.
- Le parcours reste sur le domaine de départ, sauf `--allow-host` explicite.
- Les téléchargements déclenchés par un bouton de la page sont interceptés et
  enregistrés eux aussi.
- Les réponses non-HTML (JSON, CSV) sont enregistrées telles quelles, et non
  dans l'habillage HTML de la visionneuse du navigateur.
- Une redirection vers la page de connexion interrompt le parcours au lieu de
  recopier des centaines de pages de login.

## Dépannage

**Pages vides ou incomplètes** — le portail charge son contenu en JavaScript
après l'événement réseau : ajoute `--settle 3`.

**Le parcours trouve très peu de liens** — la navigation passe peut-être par
des boutons plutôt que des `<a href>`. Repère l'URL d'une section dans la barre
d'adresse et lance un `crawl` séparé avec cette URL en `--url`.

**`state.json` introuvable** — l'étape `login` n'a pas été faite, ou tu n'es pas
dans le même répertoire. Le chemin se règle avec `--state`.

## Sécurité

`state.json` contient des cookies de session valides : il donne accès au compte.
Il est exclu du dépôt par `.gitignore` — garde-le privé et supprime-le une fois
le téléchargement terminé.
