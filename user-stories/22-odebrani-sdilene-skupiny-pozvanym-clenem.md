# Odebrání sdílené skupiny pozvaným členem

## Cíl
Pozvaný člen chce odebrat skupinu ze své aplikace, aniž by smazal data vlastníků plánů nebo svoje osobní plány.

## Předpoklady
Uživatel je pozvaný člen skupiny a skupina je viditelná v aplikaci.

## Scénář
1. Uživatel otevře `Skupina`.
2. Zvolí odebrání sdílené skupiny ze své aplikace.
3. Aplikace vysvětlí, že se odebere jen jeho přístup k této skupině.
4. Uživatel akci potvrdí.
5. Aplikace odebere přístup ke skupinovému úložišti podle možností CloudKitu.
6. Sdílené plány, dávky, historie a alarmy této skupiny zmizí z jeho zařízení.
7. Osobní plány a ostatní skupiny zůstanou dostupné.

## Očekávaný výsledek
Pozvaný člen může skupinu opustit bez destruktivního zásahu do dat vlastníka plánů nebo ostatních členů.

## Chybové stavy
- Pokud odebrání přístupu selže, skupina zůstane viditelná.
- Pokud zařízení není online, aplikace zobrazí varování a stav se nezmění jako úspěšný.
- Pokud uživatel akci zruší, nic se neodebere.
