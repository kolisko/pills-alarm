# Restart telefonu a opětovné spuštění

## Cíl
Uživatel chce po restartu telefonu znovu otevřít aplikaci a mít jistotu, že plán, potvrzení a alarmy odpovídají CloudKitu.

## Předpoklady
Telefon byl restartovaný a aplikace se spouští znovu.

## Scénář
1. Uživatel restartuje telefon.
2. Uživatel otevře aplikaci.
3. Aplikace ověří dostupnost iCloudu.
4. Aplikace načte osobní i sdílené CloudKit prostory.
5. Aplikace obnoví stav `Plán`, `Dnes`, `Skupina` a `Historie`.
6. Aplikace z aktuálních cloudových dat přepočítá lokální alarmy.
7. Uživatel vidí aktuální plán a potvrzení.
8. Uživatel vidí v auditu alarmů aktuální čekající alarmy.

## Očekávaný výsledek
Restart telefonu nezpůsobí ztrátu plánů ani ponechání alarmů v nesouladu s CloudKitem.

## Chybové stavy
- Pokud iCloud po restartu není dostupný, aplikace zobrazí obrazovku iCloud.
- Pokud reload selže, aplikace zobrazí chybu synchronizace a případný poslední známý stav ponechá jen pro čtení.
- Dokud reload z CloudKitu neproběhne úspěšně, aplikace zakáže akce zapisující do iCloudu.
- Pokud notifikace po restartu nejsou povolené, audit alarmů to ukáže.
