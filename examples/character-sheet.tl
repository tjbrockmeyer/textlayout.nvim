Bob the Bold
> ============
{DEXTERITY=14}
{CONSTITUTION=12}
{WISDOM=10}
{DEX=floor((DEXTERITY-10)/2)}
{CON=floor((CONSTITUTION-10)/2)}
{WIS=floor((WISDOM-10)/2)}
{PROF=2}
{NAME="Bob"}

Name | {NAME}
> DEX  | {DEXTERITY} ({DEX})
> CON  | {CONSTITUTION} ({CON})
> WIS  | {WISDOM} ({WIS})

Attack | {DEX+PROF}
> AC     | {10+DEX}

@grid [
HP {20+DEX}  | AC {10+DEX}       | INIT {DEX}
> STR 14      | DEX {DEXTERITY}   | CON {CONSTITUTION}
> WIS {WISDOM} | INT 12           | CHA 8
]
