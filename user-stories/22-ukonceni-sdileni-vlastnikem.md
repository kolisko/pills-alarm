# Ukončení sdílení vlastníkem

## Cíl
Vlastník skupiny chce ukončit CloudKit share skupiny tak, aby členové už neviděli plány přidané do této skupiny.

## Předpoklady
Existuje skupina, uživatel je jejím vlastníkem a alespoň jeden další člen přijal pozvánku.

## Scénář
1. Vlastník otevře `Skupina`.
2. Zvolí ukončení sdílení skupiny.
3. Aplikace zobrazí potvrzení destruktivní akce.
4. Vlastník akci potvrdí.
5. Aplikace ukončí CloudKit share skupiny.
6. Plány přidané do skupiny zůstanou jejich vlastníkům jako soukromé.
7. Členové po synchronizaci ztratí přístup ke skupinovým plánům, historii a alarmům.

## Očekávaný výsledek
Ukončení sdílení odstraní skupinu členům, ale nemaže osobní plány ani osobní úložiště žádného uživatele.

## Chybové stavy
- Pokud ukončení sdílení selže, skupina zůstane aktivní.
- Pokud některý člen není online, změnu uvidí po dalším úspěšném reloadu.
