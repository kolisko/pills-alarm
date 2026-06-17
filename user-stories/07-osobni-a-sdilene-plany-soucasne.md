# Osobní a sdílené plány současně

## Cíl
Uživatel chce v jedné aplikaci vidět svoje soukromé plány i plány sdílené v přijatých nebo vlastních skupinách.

## Předpoklady
Uživatel má soukromý plán a alespoň jeden plán sdílený ve skupině.

## Scénář
1. Aplikace načte osobní úložiště.
2. Aplikace načte dostupná skupinová úložiště.
3. Uživatel otevře `Plán`.
4. Aplikace zobrazí soukromé i sdílené plány v jednom seznamu.
5. Sdílené položky mají ikonu sdílení.
6. Uživatel otevře `Dnes`.
7. Aplikace zobrazí dávky ze soukromých i sdílených plánů.
8. Uživatel otevře `Historie`.
9. Aplikace zobrazí osobní i sdílenou historii s označením zdroje.

## Očekávaný výsledek
Uživatel nemusí ručně přepínat úložiště. Aplikace rozlišuje soukromé a sdílené plány vizuálně a nespojuje podobné dávky z různých úložišť.

## Chybové stavy
- Pokud se skupinové úložiště nenačte, osobní data zůstanou viditelná.
- Pokud osobní úložiště selže kvůli iCloud účtu, aplikace zobrazí obrazovku `iCloud`.
- Pokud selže jen síťový reload, aplikace zobrazí varování a nemění lokální UI stav jako úspěšný.
