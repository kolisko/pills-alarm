# Refresh a periodická synchronizace

## Cíl
Uživatel chce, aby se otevřená aplikace sama pravidelně srovnávala s CloudKitem a nedržela starý stav.

## Předpoklady
Aplikace je otevřená, iCloud je dostupný a existují osobní nebo sdílené plány.

## Scénář
1. Uživatel nechá aplikaci otevřenou.
2. Aplikace po spuštění načte osobní a sdílené CloudKit prostory.
3. Aplikace nastaví pravidelnou synchronizaci pro otevřenou aplikaci.
4. Jiný telefon nebo jiný člen skupiny změní plán nebo potvrdí dávku.
5. Aplikace při nejbližší synchronizační příležitosti spustí reload.
6. Aplikace načte aktuální CloudKit stav.
7. Aplikace aktualizuje `Plán`, `Dnes`, `Historie` a lokální alarmy.
8. Uživatel vidí nový stav bez ručního restartu aplikace.

## Očekávaný výsledek
Otevřená aplikace se nespoléhá jen na silent push. Má i vlastní periodický reload a ruční pull-to-refresh.

## Chybové stavy
- Pokud periodický reload selže, aplikace zobrazí centrální chybu.
- Pokud je zařízení offline, aplikace může ponechat poslední známý stav pro čtení a procházení obrazovek, ale zakáže akce zapisující do iCloudu.
- Po návratu připojení a úspěšném reloadu aplikace znovu povolí mutace podle aktuálního CloudKit stavu.
- Pokud během reloadu přijde další změna, aplikace provede další reload a skončí v aktuálním stavu.
