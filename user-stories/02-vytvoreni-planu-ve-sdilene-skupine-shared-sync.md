# Vytvoření nebo přidání plánu do skupiny - shared sync

## Cíl
Vlastník plánu chce jeden konkrétní plán sdílet se skupinou, aby členové viděli jeho dávky a mohli je potvrzovat nebo přeskakovat.

## Předpoklady
Existuje skupina, alespoň jeden člen přijal iCloud sdílení a uživatel je vlastníkem plánu.

## Scénář
1. Uživatel otevře detail soukromého plánu nebo obrazovku `Skupina`.
2. Aplikace nabídne přidání konkrétního vlastního plánu do skupiny.
3. Uživatel zvolí sdílení plánu.
4. Aplikace zařadí plán do skupinového prostoru napojeného na CloudKit share skupiny.
5. Aplikace zařadí dosavadní běžnou historii tohoto plánu do stejného skupinového prostoru.
6. Uživatel vidí plán označený jako sdílený.
7. Členové skupiny po synchronizaci vidí stejný plán v `Plán`, dávky v `Dnes` a historii se sdílenou ikonou.

## Očekávaný výsledek
Sdílí se jen vybraný plán, ne všechny soukromé plány vlastníka. Plán může být sdílený nejvýše v jedné skupině.

## Chybové stavy
- Pokud uživatel není vlastníkem plánu, aplikace sdílení nenabídne nebo ho odmítne.
- Pokud skupinový prostor není dostupný, plán zůstane soukromý.
- Pokud zápis nebo přenos historie selže, UI se netváří jako úspěšně změněné a zobrazí varování.
