# Pravidla a slovník

## Cíl
Tento dokument sjednocuje pojmy používané v user stories.

## Zdroj pravdy
CloudKit je jediný zdroj pravdy pro plány, potvrzení, přeskočení, profily členů a sdílené skupiny. Lokální UI může změnit stav až po úspěšném zápisu nebo po načtení z CloudKitu.

Pokud CloudKit zápis selže kvůli síti nebo dočasné chybě, aplikace zobrazí varování a ponechá původní stav na obrazovce. Akci může uživatel zkusit znovu.

Pokud systém hlásí, že iCloud účet není přihlášený nebo je omezený, aplikace zobrazí obrazovku `iCloud` s cestou do nastavení iOS. Nezobrazuje falešně prázdné plány ani historii.

## Datové prostory a CloudKit databáze
`Datový prostor` je aplikační pojem. Popisuje, pod který aplikační root/share patří plán, členové a potvrzení.

`Osobní prostor` obsahuje soukromé plány uživatele. `Skupinový prostor` obsahuje profily členů a plány, které jejich vlastník výslovně přidal do skupiny.

`CloudKit private databáze` a `CloudKit shared databáze` jsou technické CloudKit scopes. Vlastníkova data sdílená přes `CKShare` zůstávají v jeho CloudKit private databázi. Pozvaný člen stejná sdílená data vidí přes svoji CloudKit shared databázi. Proto `private` v CloudKitu neznamená produktově `nesdílené`.

Slovo `úložiště` se v user stories nepoužívá samostatně, protože je nejednoznačné. Pokud je potřeba mluvit o produktu, používá se `osobní prostor` nebo `skupinový prostor`. Pokud je potřeba mluvit o CloudKitu, používá se `CloudKit private databáze` nebo `CloudKit shared databáze`.

## Plány a sdílení
Plán je buď soukromý, nebo sdílený právě v jedné skupině. Sdílení plánu není kopie.

Skupina je adresář členů a technický share. Sama o sobě nenasdílí všechny soukromé plány. Vlastník plánu rozhoduje, který svůj plán do skupiny přidá nebo ze skupiny odebere.

Sdílený plán upravuje a ze skupiny odebírá jen vlastník plánu. Členové skupiny mohou dávky potvrzovat, přeskakovat a vracet potvrzení nebo přeskočení, pokud mají ve skupině vyplněné jméno.

Při přidání soukromého plánu do skupiny se plán zařadí do skupinového prostoru a sdílí se přes skupinový `CKShare`. U vlastníka zůstává v CloudKit private databázi. Pozvaným členům se objeví v jejich CloudKit shared databázi. Do skupinového prostoru se zároveň zařadí jeho dosavadní běžná historie. Při odebrání plánu ze skupiny plán a historie zůstanou vlastníkovi, ale členům po synchronizaci zmizí.

## Identita dávky a konflikty
Dávka a její cloudový stav se identifikují stabilním identifikátorem dávkovacího slotu a konkrétního dne v příslušném datovém prostoru. Název léku, čas, množství ani pořadí v seznamu nejsou identita dávky.

Pokud uživatel upraví čas nebo množství existujícího dávkovacího slotu, identita slotu zůstává stejná.

Pokud uživatel smaže dávkovací slot nebo plán, aplikace smaže jeho budoucí dávky, alarmy a odpovídající potvrzení nebo přeskočení z běžné `Historie`.

Pokud pro stejnou dávku vzniknou skoro současné akce, první úspěšně zapsaný cloudový stav vyhrává. Pozdější protichůdný zápis se neprovede a aplikace tichým refreshem zobrazí existující cloudový stav.

## Historie
`Historie` je běžný uživatelský pohled odvozený z aktuálních cloudových potvrzení a přeskočení. Není to append-only audit log.

Pokud uživatel vrátí potvrzení nebo přeskočení, aplikace smaže odpovídající cloudový stav. Po synchronizaci se tento záznam v běžné `Historii` už nezobrazuje.

## Alarmy
Lokální alarmy jsou odvozený stav. Aplikace je přepočítává z aktuálních plánů, potvrzení, přeskočení a lokálního nastavení alarmů.

## Úrovně dopadu
- `jedno zařízení` popisuje okamžitý dopad na zařízení, které akci provádí, po úspěšném CloudKit zápisu.
- `private sync` popisuje propsání osobních dat mezi zařízeními stejného iCloud účtu.
- `shared sync` popisuje propsání sdílených dat mezi členy stejné sdílené skupiny.
