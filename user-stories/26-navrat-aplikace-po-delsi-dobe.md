# Návrat aplikace po delší době

## Cíl
Uživatel chce po otevření aplikace po delší době vidět aktuální cloudový stav a aktuální alarmy.

## Předpoklady
Aplikace byla delší dobu v pozadí nebo nebyla spuštěná a mezitím mohlo dojít ke změnám na jiných zařízeních.

## Scénář
1. Uživatel otevře aplikaci po delší době.
2. Aplikace přejde do popředí.
3. Aplikace spustí reload z CloudKitu.
4. Aplikace načte osobní i sdílené prostory.
5. Aplikace aktualizuje `Plán`, `Dnes`, `Skupina` a `Historie`.
6. Aplikace aktualizuje lokální alarmy podle aktuálního CloudKit stavu.
7. Uživatel vidí aktuální dávky a potvrzení.
8. Uživatel v `Alarmy` vidí nový čas posledního přeplánování.

## Očekávaný výsledek
Po návratu do aplikace se lokální stav srovná s CloudKitem bez nutnosti ručního restartu nebo ručního refreshnutí.

## Chybové stavy
- Pokud reload selže, aplikace zobrazí chybu a nechá poslední známý stav jen pro čtení.
- Pokud zařízení není online, aplikace nechá poslední známý stav jen pro čtení a zakáže akce zapisující do iCloudu.
- Po obnovení připojení a úspěšném reloadu aplikace znovu povolí mutace podle aktuálního CloudKit stavu.
- Pokud během reloadu přijde další změna, aplikace provede další synchronizaci a skončí v aktuálním stavu.
