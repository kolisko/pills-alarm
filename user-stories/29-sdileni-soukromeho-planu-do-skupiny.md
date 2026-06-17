# Sdílení soukromého plánu do skupiny

## Cíl
Vlastník chce v detailu plánu rozhodnout, jestli konkrétní plán zůstane soukromý, nebo bude sdílený v jeho skupině.

## Předpoklady
Uživatel má soukromý plán. Skupina může, ale nemusí existovat.

## Scénář
1. Uživatel otevře detail soukromého plánu.
2. Pokud skupina neexistuje, aplikace ukáže, že sdílení je zamčené a plán zůstává soukromý.
3. Pokud skupina existuje, uživatel zapne sdílení.
4. Aplikace zařadí plán a jeho běžnou historii do skupinového prostoru sdíleného přes skupinový `CKShare`.
5. U vlastníka záznamy zůstávají v CloudKit private databázi; členové skupiny je po synchronizaci vidí ve své CloudKit shared databázi.
6. Uživatel může později sdílení vypnout.
7. Aplikace vrátí plán vlastníkovi jako soukromý a členům ho po synchronizaci odstraní.

## Očekávaný výsledek
Sdílení plánu je explicitní volba pro jeden plán. UI se změní až po úspěšném CloudKit zápisu.

## Chybové stavy
- Pokud změna sdílení selže, plán zůstane v původním stavu a aplikace zobrazí varování.
- Pokud plán už je sdílený v jedné skupině, aplikace ho nedovolí sdílet do další skupiny.
