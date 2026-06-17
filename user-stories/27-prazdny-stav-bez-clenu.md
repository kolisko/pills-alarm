# Prázdný stav bez dalších členů

## Cíl
Uživatel chce ve skupině vidět, že zatím nejsou žádní další členové, a mít možnost někoho pozvat.

## Předpoklady
Uživatel vytvořil skupinu, ale nikdo další ještě nepřijal pozvánku nebo nevytvořil profil.

## Scénář
1. Uživatel otevře `Skupina`.
2. Aplikace zobrazí sekci `Skupina`.
3. Aplikace zobrazí sekci `Ostatní členové`.
4. Aplikace zjistí, že neexistují žádní další členové.
5. Uživatel vidí text `Zatím žádní další členové`.
6. Uživatel vidí tlačítko `Pozvat přes iCloud`.
7. Uživatel může otevřít systémové pozvání.

## Očekávaný výsledek
Prázdný seznam členů nevadí používání skupiny a uživatel má jasnou cestu k pozvání dalších lidí.

## Chybové stavy
- Pokud se členové nepodaří načíst, aplikace zobrazí chybu synchronizace.
- Pokud pozvaný člen ještě nevyplnil jméno, nemusí být vidět jako pojmenovaný člen.
- Pokud pozvánka selže, seznam členů se nezmění.
