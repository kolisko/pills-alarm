# Přijatý člen se zobrazí ostatním

## Cíl
Členové skupiny chtějí vidět, kdo už pozvánku přijal a vytvořil si profil ve skupině.

## Předpoklady
Vlastník odeslal iCloud pozvánku a pozvaný uživatel ji přijal.

## Scénář
1. Uživatel B přijme pozvánku do sdílené skupiny.
2. Aplikace uživatele B načte skupinové úložiště.
3. Aplikace vyzve uživatele B k zadání jeho jména ve skupině.
4. Uživatel B zadá jméno a klepne na `Uložit`.
5. Aplikace uloží profil uživatele B do skupinové úložištěu vlastníka.
6. Uživatel A provede synchronizaci.
7. Aplikace uživatele A načte skupinové úložiště.
8. Aplikace uživatele A zobrazí uživatele B v sekci `Ostatní členové`.
9. Uživatel A vidí jméno, které si uživatel B sám nastavil.

## Očekávaný výsledek
Pozvaný člen se ostatním členům zobrazí až po přijetí pozvánky a vytvoření vlastního profilu.

## Chybové stavy
- Pokud uživatel B nevyplní jméno, ostatní členové ho nemusí vidět jako pojmenovaného účastníka.
- Pokud synchronizace u uživatele A selže, nový člen se zobrazí po dalším reloadu.
- Odesílatel pozvánky neurčuje jméno pozvaného uživatele.
