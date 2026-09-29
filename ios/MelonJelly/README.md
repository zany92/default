# Melon Jelly — iOS / iPadOS (Metal)

Portage natif Swift + Metal de l’étude interactive « Melon Jelly Knife » (WebGPU) :
une tranche de pastèque en gelée, simulée en volume, que l’on étire à la main
ou que l’on découpe au couteau. App universelle iPhone + iPad.

## Ouvrir et lancer

1. Ouvrir `MelonJelly.xcodeproj` dans Xcode 15 ou plus récent.
2. Cible **MelonJelly** → *Signing & Capabilities* → choisir votre équipe
   (et changer l’identifiant `com.example.MelonJelly` si besoin).
3. Lancer sur un iPhone / iPad réel (iOS 16+) ou sur le simulateur.

Le projet peut aussi être régénéré avec [XcodeGen](https://github.com/yonaskolb/XcodeGen) : `xcodegen` dans ce dossier.

> Le solveur physique tourne sur le CPU : le projet compile en `-O` même en Debug pour rester fluide.

## Interactions

| Geste | Main | Couteau |
|---|---|---|
| Un doigt sur la tranche | attrape et tire le morceau touché | trace la ligne de coupe ; le couteau s’aligne et coupe au relâcher |
| Un doigt dans le vide | fait tourner la caméra | — |
| Second doigt pendant une prise | tord la zone tenue | — |
| Pincement (en orbite) | zoom | — |
| Double-tap dans le vide | recentre la caméra | — |

Le panneau propose : outil, variété (Crimson, Golden, Rosé), fermeté, amortissement interne,
pichenette, réinitialisation, vitesse ¼, affichage du maillage, pause, et une fiche
« À l’intérieur de l’expérience ». Sur iPad le panneau est latéral, sur iPhone il est en bas.
Le pointeur du trackpad / de la souris sur iPad fait survoler le couteau.

## Architecture

| Fichier | Rôle |
|---|---|
| `Geometry.swift` | forme de la tranche, PRNG, Delaunay (Bowyer–Watson), plongement barycentrique |
| `Pieces.swift` | morceaux convexes à coins arrondis, découpe, maillages de simulation (tétraèdres) et de rendu, pépins et bulles |
| `SoftBody.swift` | XPBD : contraintes co-rotationnelles par tétraèdre, volume, prise, sol avec frottement, collisions entre morceaux, lame, amortissement le long des arêtes |
| `KnifeMesh.swift` | maillage du couteau nakiri (lame, mitre, manche) |
| `Engine.swift` | boucle à pas fixe (60 Hz × 10 sous-pas), skinning, caméra, lumière, picking, chorégraphie de la découpe, gestes |
| `Renderer.swift` | passes Metal : carte d’ombre, carte de hauteur (occlusion de contact), scène MSAA 4×, profondeur des faces arrière, gelée, maillage, tone mapping |
| `Shaders.metal` | studio procédural, ombres douces PCSS, réfraction, absorption Beer–Lambert, diffusion, lueur en contre-jour, Fresnel/GGX, PBR Neutral |
| `ContentView.swift`, `AppModel.swift`, `JellyMetalView.swift` | interface SwiftUI adaptative et vue `MTKView` |
